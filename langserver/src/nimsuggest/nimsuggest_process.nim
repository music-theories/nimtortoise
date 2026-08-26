import std/[options, strformat, strutils, sets, tables, times, json, sequtils, algorithm]
import chronos
import chronicles

import forest

import ../utils/utils
import ../utils/process_utils

import ../configurations/configurations
import ../protocol/types

import ./[suggestapi, suggestapi_types, nimsuggest_types, nimsuggest_slots, diagnostics, nimsuggest_utils, nimsuggest_dependencies]

# Interactive queries that take longer than this with an empty result indicate
# nimsuggest is spinning in unbounded generic instantiation that terminates via
# stack overflow before the per-request TCP timeout fires.  One such response
# is enough to call markFailed and trigger crash-recovery — healthy nimsuggest
# always returns quickly on these query kinds after the first CHANGED compiles
# the module graph.
# const SlowEmptyThresholdMs = 10_000

# Claude thinks (I'm sceptical):
# Pass "-" as the file path to chk so the nimsuggest v4 shared preamble does
# not touch any real file's stash. Specifically:
# - chk(path, ...) would call msgs.setDirtyFile(conf, path_idx, ""), clearing
#   the stash that `changed "X";"stash"` just registered.
# - chk("-", ...) targets the "-" sentinel; setDirtyFile for a non-module is
#   harmless. The stash for the changed file remains registered.
# - ideChk then calls graph.needsCompilation() (global, not per-file), which
#   returns true because changed + stash markDirtyIfNeeded marked the file dirty.
# - graph.recompilePartially() uses toFullPathConsiderDirty, so the changed file
#   is compiled from the stash (new content), and transitive dependents cascade.
# recompile() (ideRecompile) was tried but calls recompileFullProject() which
# rebuilds from disk, ignoring stash content.
# return await ns.chk(path, q.dirtyFile)
# return await ns.recompile()

# === PROCESSING ===
proc runNimsuggestQuery*(
  ns: Nimsuggest, 
  q: NimsuggestQuery[NimsuggestFilePosition],
): Future[seq[Suggest]] {.async.} =
  let path = toFilePathAbs(q.uri)
  case q.kind
  of NimsuggestQueryKind.SUGGEST:
    return await ns.sug(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DEFINITION:
    return await ns.def(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DECLARATION:
    return await ns.declaration(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.TYPE_DEFINITION:
    return await ns.type(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.REFERENCES:
    return await ns.use(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.HOVER, NimsuggestQueryKind.DOCUMENT_HIGHLIGHT:
    return await ns.highlight(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.SIGNATURE_HELP:
    return await ns.con(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DOCUMENT_SYMBOLS:
    return await ns.outline(path, q.dirtyFile)
  of NimsuggestQueryKind.WORKSPACE_SYMBOLS:
    return await ns.globalSymbols(path, q.dirtyFile)
  of NimsuggestQueryKind.INLAY_HINTS:
    return await ns.inlayHints(
      path, q.dirtyFile,
      q.inlayHints.start.line, q.inlayHints.start.col,
      q.inlayHints.finish.line, q.inlayHints.finish.col,
      q.inlayHints.options
    )
  of NimsuggestQueryKind.EXPAND:
    return await ns.expand(
      path, 
      q.dirtyFile, 
      q.expand.position.line, q.expand.position.col, 
      q.expand.tag
    )
  of NimsuggestQueryKind.CHANGED:
    return await ns.changed(path, q.dirtyFile)
  of NimsuggestQueryKind.CHECK_FILE:
    return await ns.chkFile(path, q.dirtyFile)
  of NimsuggestQueryKind.CHECK_PROJECT:

    return await ns.chk(path, q.dirtyFile)
    # Claude thinks "passing "-" as the file path to chk so the nimsuggest v4 shared preamble does not touch any real file's stash.  I'm not so sure this is a good idea.
    # return await ns.chk(FilePathAbs("-"), FilePathAbs(""))
  of NimsuggestQueryKind.RECOMPILE:
    return await ns.recompile()
  of NimsuggestQueryKind.KNOWN:
    return await ns.known(path)
  of NimsuggestQueryKind.SHUTDOWN:
    doAssert false, "SHUTDOWN must not reach runNimsuggestQuery"

proc processNimsuggestQuery*(
  slot: NimsuggestSlot,
  q: NimsuggestQuery[NimsuggestFilePosition],
  openFiles: TableRef[FileUri, NlsFileInfo],
  dependencies: Forest,
  storageDir: DirPathAbs,
  config: NlsConfig,
  notifyProc: proc(name: string, params: JsonNode) {.gcsafe, raises: [].}, #Send a notification to the client
) {.async.} = 
  try:
    # === RUNNING NIMSUGGEST QUERY ===
    debug "processNimsuggestQueries: running query ", entryPoint = slot.spawnInfo.entryPoint, kind = $q.kind, uri = $q.uri

    let queryResponse: seq[Suggest] = await runNimsuggestQuery(slot.ns.read(), q)

    q.responseFuture.complete(queryResponse)

    case q.kind
    of NimsuggestQueryKind.CHANGED:
      debug "processNimsuggestQueries: CHANGED complete, scanning open files for dependents"
      if q.uri in openFiles:
        openFiles[q.uri].lastChanged = now()

      if not q.isDependency:
        let dependencyQueriesToSend = createNimsuggestDependencyQueries(
          q, storageDir, openFiles, dependencies,
          config
        )

        for msg in reversed(dependencyQueriesToSend):
          debug "processNimsuggestQueries: dependency to queue", kind = $msg.kind,uri = msg.uri
          slot.queryMailbox.addFirstNoWait(msg)

    of NimsuggestQueryKind.CHECK_FILE:
      if q.uri in openFiles:
        openFiles[q.uri].lastChecked = now()

      let diagnosticsJson = convertNimSuggestResponseToDiagnostics(
        queryResponse, q.uri, openFiles
      )
      notifyProc("textDocument/publishDiagnostics", diagnosticsJson)

    of NimsuggestQueryKind.CHECK_PROJECT, NimsuggestQueryKind.RECOMPILE:
      let timeNow = now()
      for uri, file in openFiles:
        openFiles[uri].lastChecked = timeNow

      var filesWithDiagnostics: HashSet[FileUri]
      for (path, groupedSuggests) in groupBy(queryResponse, getFilepath):
        let uri = toUri(path)
        filesWithDiagnostics.incl(uri)

        let diagnosticsJson = convertNimSuggestResponseToDiagnostics(
          groupedSuggests, uri, openFiles
        )

        notifyProc("textDocument/publishDiagnostics", diagnosticsJson)

    else:
      discard

  except CatchableError as ex:
    debug "processQueries: query failed",
      projectFile = slot.spawnInfo.entryPoint, kind = $q.kind, msg = ex.msg
    
    slot.crashedUris.incl(q.uri)
    
    if slot.ns.read().failed:
      slot.state = SlotState.CRASHED

    if not q.responseFuture.finished:
      q.responseFuture.complete(@[]) 
      # empty, not fail — see fix #17
  
proc filterMailbox(
  slot: NimsuggestSlot,
  originalQuery: NimsuggestQuery[LspFilePosition],
  openFiles: TableRef[FileUri, NlsFileInfo],
  config: NlsConfig,
): Future[bool] {.async.} = 
  ## Returns a boolean.  
  ## If continue processing, if false, skip processing and move to the next query.
  case originalQuery.kind
  of NimsuggestQueryKind.CHANGED:
    if mailboxHasChangedQueryForSameUriAnyOtherUri(slot, originalQuery.uri) and (originalQuery.saved == false) and (originalQuery.isDependency == false):
      # If there is a later changed query for the same uri queued, drop this one.  There must be no CHANGED queries to other URIs in between, though.
      debug "processNimsuggestQueries: There is a later CHANGED query for the same uri.", uri = originalQuery.uri

      originalQuery.responseFuture.complete(@[])
      return false

    else:
      if originalQuery.uri in openFiles:
        let fileInfo = openFiles[originalQuery.uri]
        let timeSinceLastChange = now() - fileInfo.lastChanged

        if timeSinceLastChange < config.performance.fileCheckThrottling:
          # Not enough time has elapsed
          let timeoutLength = (config.performance.fileCheckThrottling - timeSinceLastChange).inMilliseconds + 5

          debug "processNimsuggestQueries: Running timeout for CHANGED.", timeout = timeoutLength, uri = originalQuery.uri

          await sleepAsync(timeoutLength)
          slot.queryMailbox.addFirstNoWait(originalQuery)
          return false

        else:
          # else: enough time has passed, continue with processing the query...
          return true

      else:
        debug "processNimsuggestQueries: File is not open.", uri = originalQuery.uri
        return true

  of NimsuggestQueryKind.CHECK_FILE:
    if mailboxHasQueryOfKind(
      slot, NimsuggestQueryKind.CHECK_FILE, originalQuery.uri
    ):
      debug "processNimsuggestQueries: skipping stale query (CHECK_FILE pending)", kind = $originalQuery.kind, uri = originalQuery.uri
      
      originalQuery.responseFuture.complete(@[])
      return false
      

  of NimsuggestQueryKind.CHECK_PROJECT:
    discard
  of NimsuggestQueryKind.RECOMPILE:
    discard
  of 
    NimsuggestQueryKind.SUGGEST,
    NimsuggestQueryKind.DOCUMENT_SYMBOLS, 
    NimsuggestQueryKind.INLAY_HINTS,
    NimsuggestQueryKind.HOVER,
    NimsuggestQueryKind.DOCUMENT_HIGHLIGHT,
    NimsuggestQueryKind.SIGNATURE_HELP:
    # skip if a newer query, or if a CHANGED is still pending (AST is
    # stale — results would be wrong anyway and VS Code will re-request).
    if mailboxHasQueryOfKind(
      slot, NimsuggestQueryKind.CHANGED, originalQuery.uri
    ):
      debug "processNimsuggestQueries: skipping stale query (CHANGED pending)", kind = $originalQuery.kind, uri = originalQuery.uri
      originalQuery.responseFuture.complete(@[])
      return false

    elif mailboxHasQueryOfKind(
      slot, originalQuery.kind, originalQuery.uri
    ):
      debug "processNimsuggestQueries: skipping stale query (a newer request is later in the queue)", kind = $originalQuery.kind, uri = originalQuery.uri
      originalQuery.responseFuture.complete(@[])
      return false

  of
    NimsuggestQueryKind.DEFINITION,
    NimsuggestQueryKind.DECLARATION,
    NimsuggestQueryKind.TYPE_DEFINITION,
    NimsuggestQueryKind.REFERENCES,
    NimsuggestQueryKind.WORKSPACE_SYMBOLS,
    NimsuggestQueryKind.EXPAND,
    NimsuggestQueryKind.KNOWN,
    NimsuggestQueryKind.SHUTDOWN:
    discard

  return true

proc processNimsuggestQueries*(
  slot: NimsuggestSlot,
  pool: NimsuggestPool,
  openFiles: TableRef[FileUri, NlsFileInfo],
  dependencies: Forest,
  storageDir: DirPathAbs,
  config: NlsConfig,
  notifyProc: proc(name: string, params: JsonNode) {.gcsafe, raises: [].}, #Send a notification to the client
) {.async.} =
  debug "processNimsuggestQueries: starting", projectFile = slot.spawnInfo.entryPoint
  var shutdownFut: Future[void] = nil
  while true:
    debug "processNimsuggestQueries: waiting for query", projectFile = slot.spawnInfo.entryPoint, mailboxLen = slot.queryMailbox.len

    let originalQuery = await slot.queryMailbox.popFirst()

    if originalQuery.kind == NimsuggestQueryKind.SHUTDOWN:
      debug "processNimsuggestQueries: received SHUTDOWN, exiting loop", projectFile = slot.spawnInfo.entryPoint

      shutdownFut = originalQuery.shutdownFuture

      # Drain any queries that arrived after the SHUTDOWN sentinel so their
      # futures are resolved and callers are not left waiting forever.
      while slot.queryMailbox.len > 0:
        let drainedQuery = slot.queryMailbox.popFirstNoWait()
        if not drainedQuery.responseFuture.finished:
          drainedQuery.responseFuture.complete(@[])

      break

    # $/cancelRequest — skip queries already cancelled by the client.
    if originalQuery.cancelled:
      debug "processNimsuggestQueries: query cancelled, skipping", kind = $originalQuery.kind, uri = originalQuery.uri
      if not originalQuery.responseFuture.finished:
        originalQuery.responseFuture.complete(@[])
      continue

    let continueProcessing = await slot.filterMailbox(  
      originalQuery, openFiles, config
    )
    if continueProcessing == false:
      continue
      
    # State
    case slot.state 
    of SlotState.STOPPING, SlotState.STOPPED:
      debug "processNimsuggestQueries: Could not process query, slot was STOPPING, OR STOPPED.", state = slot.state
      if not originalQuery.responseFuture.finished:
        originalQuery.responseFuture.complete(@[])
      
      continue

    of SlotState.SPAWNING:
      discard await slot.ns

    of SlotState.CRASHED:
      if slot.ns.read().failed:
        let errMsg = slot.ns.read().errorMessage
        if errMsg.len > 0:
          pool.notifyProc("window/showMessage",
            %*{"type": 1, "message": fmt"Nimsuggest crashed while processing {originalQuery.kind} on {originalQuery.uri} (project: {slot.spawnInfo.entryPoint}): {errMsg}"})

      slot.crashedUris.incl(originalQuery.uri)

      let respawnWasSuccessful = await pool.attemptCrashRespawn(slot, config)

      if respawnWasSuccessful:
        slot.crashedUris.excl(originalQuery.uri)
      else:
        if not originalQuery.responseFuture.finished:
          originalQuery.responseFuture.complete(@[])
        pool.removeSlot(slot.spawnInfo.entryPoint)
        pool.crashedSlots.incl(slot.spawnInfo.entryPoint)
        if pool.notifyProc != nil:
          pool.notifyProc("window/logMessage",
            %*{"type": 1, "message": fmt"Nimsuggest for {slot.spawnInfo.entryPoint} permanently failed. Save the file to restart."})
        while slot.queryMailbox.len > 0:
          let drainedQuery = slot.queryMailbox.popFirstNoWait()
          if not drainedQuery.responseFuture.finished:
            drainedQuery.responseFuture.complete(@[])
        break

    of SlotState.READY:
      discard
      
    let convertedQuery = toNimsuggestQuery(originalQuery, openFiles)
    if convertedQuery.isSome():
      # === RUNNING NIMSUGGEST QUERY ===
      let q = convertedQuery.get()
      await slot.processNimsuggestQuery(
        q, openFiles, dependencies, storageDir, config, notifyProc
      )
    else: 
      originalQuery.responseFuture.complete(@[])

  # --- Shutdown: kill the OS process now that the queue is drained ---
  try:
    if slot.ns.finished and not slot.ns.failed:
      let ns = slot.ns.read()
      if not ns.process.isNil:
        await shutdownChildProcess(ns.process)

  except CatchableError:
    discard  # process may already be dead; that is fine
  if shutdownFut != nil:
    shutdownFut.complete()

# These functions have to be in this file, not nimsuggest_slots, because they rely upon the `processNimsuggestQueries` function in this file.
proc restartSlot*(
  slot: NimsuggestSlot, 
  pool: NimsuggestPool, 
  openFiles: TableRef[FileUri, NlsFileInfo],
  dependencies: Forest,
  storageDir: DirPathAbs,
  config: NlsConfig,
): Future[void] {.async.} =
  let spawningInfo: NimsuggestSpawnInfo = slot.spawnInfo
  discard await pool.stopNimsuggestSlot(slot)
  slot.crashedUris.clear()
  let successfulSpawn = await pool.spawnNewNimsuggestSlot(
    spawningInfo, pool.nimsuggest, dependencies, config
  )
  if successfulSpawn.isSome():
    if spawningInfo.entryPoint in pool.crashedSlots:
      pool.crashedSlots.excl(spawningInfo.entryPoint)

    let newSlot = successfulSpawn.get()
    if pool.notifyProc != nil:
      pool.notifyProc("window/logMessage",
        %*{"type": 3, "message": fmt"Nimsuggest initialized for {spawningInfo.entryPoint}"})
    asyncSpawn newSlot.processNimsuggestQueries(
      pool, openFiles, dependencies, storageDir, config, pool.notifyProc
    )

proc restartAllNimsuggestInstances*(
  pool: NimsuggestPool, 
  openFiles: TableRef[FileUri, NlsFileInfo],
  dependencies: Forest,
  storageDir: DirPathAbs,
  config: NlsConfig,
) =
  for projectFile in pool.slots.keys.toSeq():
    if pool.slots.hasKey(projectFile):
      asyncSpawn restartSlot(
        pool.slots[projectFile], pool, openFiles, 
        dependencies, storageDir,
        config
      )

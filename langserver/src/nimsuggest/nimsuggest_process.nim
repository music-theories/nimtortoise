import std/[options, strformat, sets, tables, times, json, sequtils, sha1]
import chronos
import chronicles

import forest

import ../utils/utils
import ../utils/process_utils
import ../utils/type_mismatch_format
import ../configurations/configurations
import ../protocol/types

import ./[suggestapi, suggestapi_types, nimsuggest_types, nimsuggest_slots, diagnostics, nimsuggest_utils]

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

proc processNimsuggestQueries*(
  slot: NimsuggestSlot,
  pool: NimsuggestPool,
  openFiles: TableRef[FileUri, NlsFileInfo],
  dependencies: Forest,
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
      break

    # debug "processNimsuggestQueries: running query", kind = $originalQuery.kind, projectFile = slot.spawnInfo.entryPoint, uri = originalQuery.uri

    # $/cancelRequest — skip queries already cancelled by the client.
    if originalQuery.cancelled:
      debug "processNimsuggestQueries: query cancelled, skipping", kind = $originalQuery.kind, uri = originalQuery.uri
      if not originalQuery.responseFuture.finished:
        originalQuery.responseFuture.complete(@[])
      continue

    case originalQuery.kind
    of NimsuggestQueryKind.CHANGED:
      if mailboxHasChangedQueryForSameUriAnyOtherUri(slot, originalQuery.uri) and (originalQuery.saved == false):
        # If there is a later changed query for the same uri queued, drop this one.  There must be no CHANGED queries to other URIs in between, though.
        debug "processNimsuggestQueries: There is a later CHANGED query for the same uri.", uri = originalQuery.uri
        originalQuery.responseFuture.complete(@[])
        continue
      else:
        if originalQuery.uri in openFiles:
          let fileInfo = openFiles[originalQuery.uri]
          let timeSinceLastChange = now() - fileInfo.lastChanged

          if timeSinceLastChange < config.fileCheckDelay:
            # Not enough time has elapsed
            let timeoutLength = (config.fileCheckDelay - timeSinceLastChange).inMilliseconds + 5
            debug "processNimsuggestQueries: Running timeout for CHANGED.", timeout = timeoutLength, uri = originalQuery.uri
            # Start a blocking timer until the remaining time has elapsed
            await sleepAsync(timeoutLength)
            # Add the message back onto the front of the queue.
            slot.queryMailbox.addFirstNoWait(originalQuery)
            continue
          # else: enough time has passed, continue with processing the query...
        else:
          debug "processNimsuggestQueries: Skipping query, file is no longer open.", uri = originalQuery.uri
          continue

    
    of NimsuggestQueryKind.CHECK_FILE:
      discard
      # if mailboxHasQueryOfKind(
      #   slot, NimsuggestQueryKind.CHECK_FILE, originalQuery.uri
      # ):
      #   debug "processNimsuggestQueries: skipping stale query (CHECK_FILE pending)", kind = $originalQuery.kind, uri = originalQuery.uri
      #   originalQuery.responseFuture.complete(@[])
      #   continue

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
        continue

        # debug "processNimsuggestQueries: re-queuing query after pending CHANGED", kind = $originalQuery.kind, uri = originalQuery.uri
        # slot.queryMailbox.addLastNoWait(originalQuery)
        # continue
      elif mailboxHasQueryOfKind(
        slot, originalQuery.kind, originalQuery.uri
      ):
        debug "processNimsuggestQueries: skipping stale query (a newer request is later in the queue)", kind = $originalQuery.kind, uri = originalQuery.uri
        originalQuery.responseFuture.complete(@[])
        continue

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

    # Wait for spawning slot
    if slot.state == SlotState.SPAWNING: 
      try:
        debug "processNimsuggestQueries: Waiting for slot to spawn."
        discard await slot.ns # waits for SPAWNING → READY
      except CatchableError:
        debug "processNimsuggestQueries: Failed to spawn slot."
        # Process failed to start or crashed. Blame the in-flight URI so
        # didSave can unblock it (see fix #12C invariant).
        slot.crashedUris.incl(originalQuery.uri)
        if not originalQuery.responseFuture.finished:
          originalQuery.responseFuture.complete(@[])
        continue

    case slot.state 
    of SlotState.SPAWNING, SlotState.CRASHED, SlotState.STOPPING, SlotState.STOPPED:
      debug "processNimsuggestQueries: Could not process query, slot was SPAWNING, CRASHED OR STOPPING.", state = slot.state
      if not originalQuery.responseFuture.finished:
        originalQuery.responseFuture.complete(@[])

    of SlotState.READY:
      if slot.ns.read().failed:
        let errMsg = slot.ns.read().errorMessage
        if pool.notifyProc != nil and errMsg.len > 0:
          pool.notifyProc("window/logMessage",
            %*{"type": 1, "message": fmt"Nimsuggest ({slot.spawnInfo.entryPoint}): {errMsg}"})
        let respawnWasSuccessful = await pool.attemptCrashRespawn(slot, config)
        if not respawnWasSuccessful:
          slot.crashedUris.incl(originalQuery.uri)
          if not originalQuery.responseFuture.finished:
            originalQuery.responseFuture.complete(@[])
          continue
      
    if slot.state == SlotState.READY:

      # debug "processNimsuggestQueries: original Query ", entryPoint = slot.spawnInfo.entryPoint, kind = $originalQuery.kind, uri = $originalQuery.uri
      let convertedQuery = toNimsuggestQuery(originalQuery, openFiles)
      if convertedQuery.isNone:
        # debug "processNimsuggestQueries: query conversion failed, skipping"
        originalQuery.responseFuture.complete(@[])
        continue

      else: 
        let q = convertedQuery.get()
        # debug "processNimsuggestQueries: query about to be run ", entryPoint = slot.spawnInfo.entryPoint, kind = $q.kind, uri = $q.uri
        try:
          # === RUNNING NIMSUGGEST QUERY ===
          let queryStartTime = now()
          debug "processNimsuggestQueries: running query ", entryPoint = slot.spawnInfo.entryPoint, kind = $q.kind, uri = $q.uri
          let queryResponse: seq[Suggest] = await runNimsuggestQuery(slot.ns.read(), q)
          let elapsedMs = inMilliseconds(now() - queryStartTime)
          
          debug "processNimsuggestQueries: response ", response = $(%*queryResponse), elapsedMs  = elapsedMs

          q.responseFuture.complete(queryResponse)
          slot.lastCmdTime = now()

          # Detect slow-empty: an interactive query that took >SlowEmptyThresholdMs
          # and returned nothing means nimsuggest is stuck in unbounded generic
          # instantiation terminated by stack overflow (not our TCP timeout).
          # Call markFailed so crash-recovery restarts the slot.
          # case q.kind
          # of NimsuggestQueryKind.HOVER, NimsuggestQueryKind.SUGGEST,
          #    NimsuggestQueryKind.DEFINITION, NimsuggestQueryKind.DECLARATION,
          #    NimsuggestQueryKind.TYPE_DEFINITION, NimsuggestQueryKind.SIGNATURE_HELP,
          #    NimsuggestQueryKind.DOCUMENT_HIGHLIGHT:
          #   if queryResponse.len == 0 and elapsedMs > SlowEmptyThresholdMs:
          #     debug "processNimsuggestQueries: slow empty — triggering markFailed",
          #       kind = $q.kind, elapsedMs = elapsedMs,
          #       entryPoint = slot.spawnInfo.entryPoint
          #     slot.ns.read().markFailed(
          #       fmt"slow empty response ({elapsedMs}ms) on {q.kind}: nimsuggest unresponsive")
          # else:
          #   discard

          case q.kind
          of NimsuggestQueryKind.CHANGED:
            if q.uri in openFiles:
              openFiles[q.uri].lastChanged = now()

            let fileJustChanged = toFilePathAbs(q.uri)

            debug "processNimsuggestQueries: CHANGED complete, scanning open files for dependents",
              fileJustChanged = fileJustChanged, openFileCount = openFiles.len,
              responseLen = queryResponse.len,
              graphNodeCount = dependencies.trees.len

            var hasDependency = false
            var dependentFiles: seq[FileUri]
            for openFile, _ in openFiles:
              if openFile != q.uri:
                let fileToCheck = toFilePathAbs(openFile)
                let isDep = dependencies.trees.checkDependency(fileJustChanged.isADependencyOf(fileToCheck))
                # debug "processNimsuggestQueries: dependency check",
                #   changedFileAbs = fileJustChanged, candidateAbs = fileToCheck, isDependency = isDep

                if isDep:
                  hasDependency = true
                  dependentFiles.add(openFile)

            # Queue a cascade of CHECK_FILE commands to propagate diagnostics through
            # the dependency chain. nimsuggest's markClientsDirty is ONE level only
            # (transitive closure is disabled in compiler/modulegraphs.nim:838).
            # We manually walk the chain via intermediate files:
            #
            #   1. Self-check changed file → recompile file_a from stash,
            #                                markClientsDirty(file_a) → file_b dirty
            #   2. Check intermediates     → recompile file_b (already dirty),
            #                                markClientsDirty(file_b) → file_c dirty
            #   3. Check open dependents   → recompile file_c (now dirty) → error
            #
            # addFirstNoWait inserts at queue front, so the LAST item added runs FIRST.
            # Add in reverse execution order: dependents first, intermediates next,
            # self-check last (so self-check ends up at queue front).

            # All open files have a stash written on didOpen and updated on every
            # didChange. The stash path is storageDir / sha1(uri) & ".nim", where
            # storageDir = parentDir(q.dirtyFile). We always pass the stash so
            # nimsuggest sees the current in-memory content, not the on-disk version
            # (which may be stale when the file has unsaved changes).
            let storageDir = parentDir(q.dirtyFile)

            # Step 1: Add open dependents with their stash paths so nimsuggest
            # recompiles them against their in-memory (possibly unsaved) content.
            for f in dependentFiles:
              let stashForF = storageDir / FilePathRel($secureHash(string(f)) & ".nim")
              let checkQuery = NimsuggestQuery[LspFilePosition](
                id: 0,
                kind: NimsuggestQueryKind.CHECK_FILE,
                uri: f,
                dirtyFile: stashForF,
                responseFuture: newFuture[seq[Suggest]]("checkFile"),
              )
              slot.queryMailbox.addFirstNoWait(checkQuery)

            if hasDependency:
              debug "processNimsuggestQueries: queuing dependency cascade",
                fileJustChanged = q.uri, dependents = dependentFiles

              # Step 2: Add intermediate non-open files in countdown order so that
              # after addFirstNoWait they precede the open dependents in the queue.
              # findIntermediatePath returns closest-to-changed first (e.g. [file_b]).
              var addedIntermediates: HashSet[FileUri]
              for f in dependentFiles:
                let fileToCheck = toFilePathAbs(f)
                let intermediates = dependencies.trees.findIntermediatePath(
                  fileToCheck, fileJustChanged)
                for i in countdown(intermediates.len - 1, 0):
                  let intermediateUri = toUri(intermediates[i])
                  if intermediateUri notin openFiles and
                     intermediateUri notin addedIntermediates:
                    addedIntermediates.incl(intermediateUri)
                    let checkQuery = NimsuggestQuery[LspFilePosition](
                      id: 0,
                      kind: NimsuggestQueryKind.CHECK_FILE,
                      uri: intermediateUri,
                      dirtyFile: FilePathAbs(""),
                      responseFuture: newFuture[seq[Suggest]]("checkFile"),
                    )
                    slot.queryMailbox.addFirstNoWait(checkQuery)

              # Step 3: Self-check the changed file (added last → runs first).
              # Pass q.dirtyFile so nimsuggest reads from the stash, not disk,
              # preserving unsaved in-memory content during recompilation.
              let checkQuery = NimsuggestQuery[LspFilePosition](
                id: 0,
                kind: NimsuggestQueryKind.CHECK_FILE,
                uri: q.uri,
                dirtyFile: q.dirtyFile,
                responseFuture: newFuture[seq[Suggest]]("checkFile"),
              )
              slot.queryMailbox.addFirstNoWait(checkQuery)
            else:
              discard

          of NimsuggestQueryKind.CHECK_FILE:
            if q.uri in openFiles:
              openFiles[q.uri].lastChecked = now()

            let diagnosticsJson = convertNimSuggestResponseToDiagnostics(
              queryResponse, q.uri, openFiles
            )
            notifyProc("textDocument/publishDiagnostics", diagnosticsJson)
            # debug "processNimsuggestQueries: CHECK_FILE done",
            #   uri = q.uri, errorCount = queryResponse.len, json = diagnosticsJson
            
            # Exact split-identity errors are false positives that RECOMPILE fixes
            # reliably. Suppress misleading diagnostics and trigger RECOMPILE instead.
            # Loose module-qualifier matches (foo.Bar vs Bar) are NOT handled here —
            # they appear as an advisory note in the diagnostic message only.
            # if queryResponse.anyIt(it.forth == "Error" and isExactSplitIdentityTypeMismatch(it.doc)):
            #   debug "processNimsuggestQueries: exact split-identity detected, triggering RECOMPILE",
            #     uri = $q.uri
            #   let recompileQuery = NimsuggestQuery[LspFilePosition](
            #     id: 0,
            #     kind: NimsuggestQueryKind.RECOMPILE,
            #     uri: q.uri,
            #     dirtyFile: FilePathAbs(""),
            #     responseFuture: newFuture[seq[Suggest]]("splitIdentityRecompile"),
            #   )
            #   slot.queryMailbox.addLastNoWait(recompileQuery)  
            
          of NimsuggestQueryKind.CHECK_PROJECT, NimsuggestQueryKind.RECOMPILE:
            let timeNow = now()
            for uri, file in openFiles:
              openFiles[uri].lastChecked = timeNow

            # let errorFilePaths = queryResponse.mapIt(string(it.filepath)).deduplicate()
            # debug "processNimsuggestQueries: CHECK_PROJECT complete",
            #   totalErrors = queryResponse.len,
            #   filesWithErrors = errorFilePaths.len,
            #   errorFiles = errorFilePaths,
            #   triggeredByUri = q.uri

            # for s in queryResponse:
            #   debug "processNimsuggestQueries: result", suggest = $(%*s)


            var filesWithDiagnostics: HashSet[FileUri]
            for (path, groupedSuggests) in groupBy(queryResponse, getFilepath):
              let uri = toUri(path)
              filesWithDiagnostics.incl(uri)

              let diagnosticsJson = convertNimSuggestResponseToDiagnostics(
                groupedSuggests, uri, openFiles
              )

              notifyProc("textDocument/publishDiagnostics", diagnosticsJson)

              # debug "processNimsuggestQueries: CHECK_PROJECT sending errors",
              #   uri = uri, isOpenFile = (uri in openFiles),
              #   errorCount = groupedSuggests.len, json = diagnosticsJson

            # Clear squigglies for open files that had no errors in this project check.
            # for uri, _ in openFiles:
            #   if uri notin filesWithDiagnostics:
            #     notifyProc(
            #       "textDocument/publishDiagnostics",
            #       %*{"uri": $uri, "diagnostics": []},
            #     )
              
          else:
            discard

          # debug "processQueries: query finished running ", projectFile = slot.spawnInfo.entryPoint, kind = $q.kind

        except CatchableError as ex:
          debug "processQueries: query failed",
            projectFile = slot.spawnInfo.entryPoint, kind = $q.kind, msg = ex.msg
          
          slot.crashedUris.incl(q.uri)
          
          if not q.responseFuture.finished:
            q.responseFuture.complete(@[]) # empty, not fail — see fix #17

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
  config: NlsConfig,
): Future[void] {.async.} =
  let spawningInfo: NimsuggestSpawnInfo = slot.spawnInfo
  discard await pool.stopNimsuggestSlot(slot)
  slot.crashedUris.clear()
  let successfulSpawn = await pool.spawnNewNimsuggestSlot(
    spawningInfo, pool.nimsuggest, config
  )
  if successfulSpawn.isSome:
    asyncSpawn slot.processNimsuggestQueries(
      pool, openFiles, dependencies, config, pool.notifyProc
    )

proc restartAllNimsuggestInstances*(
  pool: NimsuggestPool, 
  openFiles: TableRef[FileUri, NlsFileInfo],
  dependencies: Forest,
  config: NlsConfig,
) =
  for projectFile in pool.slots.keys.toSeq():
    if pool.slots.hasKey(projectFile):
      asyncSpawn restartSlot(
        pool.slots[projectFile], pool, openFiles, 
        dependencies,
        config
      )

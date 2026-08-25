import std/[options, sets, tables, sequtils, strutils, strformat, json]
import chronos
import chronicles
import ../nimsuggest/nimsuggest
import ../nimble/nimble_utils
import ../protocol/types
import ../utils/utils
import ./[langserver_types, query_types]
import ./[dispatcher_utils]

proc getOpenButUnownedUris(
  ls: LanguageServer,
): seq[FileUri] = 
  result = @[]
  for f, fileInfo in ls.files.openFiles:
    let asFilePathAbs = toFilePathAbs(f)
    var owned = false
    for entryPoint, slot in ls.pool.slots:
      if asFilePathAbs == entryPoint:
        owned = true
      if f in slot.ownedUris:
        owned = true
    
    if not(owned):
      result.add(f)

proc consolidateNimsuggestInstances(
  ls: LanguageServer,
  newSlot: NimsuggestSlot,
): Future[seq[FilePathAbs]] {.async.} =
  # Consolidation: for each other slot, check if the new slot subsumes it.
  var slotsToRemove: seq[FilePathAbs] = @[]
  for projectPath, oldSlot in ls.pool.slots:
    if oldSlot.spawnInfo.entryPoint == newSlot.spawnInfo.entryPoint: continue
    
    let knownQuery = NimsuggestQuery[LspFilePosition](
      id: 0.uint,
      kind: NimsuggestQueryKind.KNOWN,
      uri: toUri(oldSlot.spawnInfo.entryPoint),
      dirtyFile: FilePathAbs(""),
      responseFuture: newFuture[seq[Suggest]]("known"),
    )
    newSlot.queryMailbox.addLastNoWait(knownQuery)
    let response = await knownQuery.responseFuture
    let newSlotKnowsOldSlot = checkNimsuggestKnownResponse(response)

    if newSlotKnowsOldSlot:
      debug "consolidateNimsuggestInstances: new slot knows old slot", newSlotEntryPoint = newSlot.spawnInfo.entryPoint, oldSlotEntryPoint = oldSlot.spawnInfo.entryPoint
      # New slot knows old slot's entry point → it imported old slot entirely.
      # Transfer all owned URIs and shut the old slot down.
      let entryPointUri = toUri(oldSlot.spawnInfo.entryPoint)
      newSlot.ownedUris.incl(entryPointUri)

      for oldSlotUri in oldSlot.ownedUris.toSeq():
        debug "consolidateNimsuggestInstances: reassign owned uri ", oldSlotUri = oldSlotUri
        
        oldSlot.ownedUris.excl(oldSlotUri)
        newSlot.ownedUris.incl(oldSlotUri)
        # If this URI is open, tell the new slot's nimsuggest about the current
        # stash so it has the right file version.
        if oldSlotUri in ls.files.openFiles:
          newSlot.queryMailbox.addLastNoWait(NimsuggestQuery[LspFilePosition](
            id: 0,
            kind: NimsuggestQueryKind.CHANGED,
            uri: oldSlotUri,
            dirtyFile: uriToStashFilePath(ls.files.storageDir, oldSlotUri),
            saved: false,
            isDependency: false,
            responseFuture: newFuture[seq[Suggest]]("consolidateChanged"),
          ))

      discard await ls.pool.stopNimsuggestSlot(oldSlot)

      slotsToRemove.add(oldSlot.spawnInfo.entryPoint)
    else:
      debug "consolidateNimsuggestInstances: new slot does not know old slot", newSlotProjectFile = newSlot.spawnInfo.entryPoint, oldSlotProjectFile = oldSlot.spawnInfo.entryPoint

  debug "consolidateNimsuggestInstances: remove slots", slotsToRemove = slotsToRemove
  for s in slotsToRemove:
    ls.pool.removeSlot(s)
  
  return slotsToRemove

proc startSlotConsumer(
  ls: LanguageServer,
  slot: NimsuggestSlot,
  params: TextDocumentItem,
) {.async.} =
  ls.addFileToOpenFiles(slot, params)
  asyncSpawn slot.processNimsuggestQueries(
    ls.pool,
    ls.files.openFiles,
    ls.dependencies,
    ls.files.storageDir,
    ls.configurations.currentConfig,
    ls.notify,
  )
  discard await ls.consolidateNimsuggestInstances(slot)

proc createSlotWithFallback(
  ls: LanguageServer,
  spawnInfo: NimsuggestSpawnInfo,
  filePath: FilePathAbs,
  params: TextDocumentItem,
): Future[Option[NimsuggestSlot]] {.async.} =
  ## Tier 1: spawn nimsuggest with the module entry point. This gives full
  ## project-wide IntelliSense and is now reliable since --exceptionInlayHints
  ## is always off. Skipped if the entry point is known-crashed or already
  ## being spawned by a concurrent open.
  ##
  ## Tier 2: if Tier 1 fails or is skipped and filePath differs from the module
  ## entry point, fall back to spawning with the opened file as entry point.
  let nimbleDir = parentDir(spawnInfo.nimbleFile.get())

  if spawnInfo.entryPoint notin ls.pool.crashedSlots and
     not ls.pool.slots.hasKey(spawnInfo.entryPoint):
    let moduleSlot = await spawnNewNimsuggestSlot(
      ls.pool, spawnInfo, ls.pool.nimsuggest, ls.dependencies, ls.configurations.currentConfig)
    if moduleSlot.isSome:
      await ls.startSlotConsumer(moduleSlot.get(), params)
      return moduleSlot
    ls.pool.crashedSlots.incl(spawnInfo.entryPoint)
    ls.notify("window/logMessage", %*{
      "type": 4,
      "message": fmt"Could not start nimsuggest for project {spawnInfo.entryPoint}. " &
        "IntelliSense will be served per-file instead of per-project.",
    })

  if filePath == spawnInfo.entryPoint:
    return none(NimsuggestSlot)

  let fileInfo = NimsuggestSpawnInfo(
    entryPoint: filePath,
    workingDir: nimbleDir,
    nimbleFile: spawnInfo.nimbleFile,
    paths: @[],
    extraArgs: @[],
  )
  let fileSlot = await spawnNewNimsuggestSlot(
    ls.pool, fileInfo, ls.pool.nimsuggest, 
    ls.dependencies, ls.configurations.currentConfig
  )
  if fileSlot.isSome():
    await ls.startSlotConsumer(fileSlot.get(), params)
  else:
    ls.pool.crashedSlots.incl(filePath)
    ls.notify("window/logMessage", %*{
      "type": 4,
      "message": fmt"Could not start nimsuggest for project {filePath}. "
    })
  return fileSlot

proc createOrphanSlot(
  ls: LanguageServer,
  filePath: FilePathAbs,
  params: TextDocumentItem,
): Future[Option[NimsuggestSlot]] {.async.} =
  ## Spawns nimsuggest with filePath as its own entry point (no project context).
  let slot = await spawnNewNimsuggestSlot(
    ls.pool, filePath, ls.files.rootPath,
    ls.pool.nimsuggest, ls.dependencies, ls.configurations.currentConfig)
  if slot.isSome:
    await ls.startSlotConsumer(slot.get(), params)
  return slot
    
proc processDidOpenQuery*(
  ls: LanguageServer, q: FileAccessQuery
) {.async.} = 
  let uri = q.didOpen.textDocument.uri
  # Check if file is already open
  if uri in ls.files.openFiles:
    debug "didOpenFile: URI is already in openFiles", uri = uri
    let slotCheck = getSlotThatOwnsUri(ls.pool, uri)
    if slotCheck.isSome():
      let slotThatOwnsUri = slotCheck.get()
      case slotThatOwnsUri.state 
      of SlotState.READY, SlotState.SPAWNING:
        if uri in slotThatOwnsUri.ownedUris:
          # The file is already marked as open and has a valid nimsuggest slot.  Our work here is done!
          return
        else:
          # Otherwise, the slot doesn't own it, so it should get checked below.
          discard
      of SlotState.STOPPING, SlotState.CRASHED:
        discard
      of SlotState.STOPPED:
        # Should restart?  This should happen below ...
        discard

  # Check if file is known to any nimsuggest instance
  debug "didOpen: calling isKnownByANimsuggestSlot", uri = uri
  let fileIsKnown: Option[NimsuggestSlot] = await isKnownByANimsuggestSlot(ls.pool, uri)
  debug "didOpen: isKnownByANimsuggestSlot returned", uri = uri, isKnown = fileIsKnown.isSome

  if fileIsKnown.isSome:
    debug "didOpen: file is known by a running nimsuggest instance.  Add file to the correct slot", uri = uri
    let slotThatKnows = fileIsKnown.get()
    ls.addFileToOpenFiles(slotThatKnows, q.didOpen.textDocument)
    slotThatKnows.queryMailbox.addLastNoWait(NimsuggestQuery[LspFilePosition](
      kind: NimsuggestQueryKind.CHECK_FILE,
      uri: uri,
      dirtyFile: uriToStashFilePath(ls.files.storageDir, uri),
      isDependency: false,
      responseFuture: newFuture[seq[Suggest]]("checkFile"),
    ))
    # Finished
  else:
    # This file is not known by any running nimsuggest instance.
    # Check there is a free nimsuggest slot
    let filePath = toFilePathAbs(uri)
    if not string(filePath).endsWith(".nim"):
      debug "didOpen: Non-.nim file, skipping nimsuggest spawn", uri = uri
      return

    debug "didOpen: Check if it has a projectFile/entryPoint.  i.e. Is a true orphan?", uri = uri, filePath = filePath
    let spawnInfo: NimsuggestSpawnInfo = getNimsuggestSpawnInfo(
      filePath, ls.files.rootPath, ls.dependencies
    )

    # does it have a relevant nimble file?
    if spawnInfo.nimbleFile.isNone():
      debug "didOpen: File has no related nimble file.  It is a true orphan. Spawning standalone nimsuggest for it.", entryPoint = filePath
      discard await createOrphanSlot(ls, filePath, q.didOpen.textDocument)

    else:
      if spawnInfo.entryPoint == filePath:
        debug "didOpen: This uri IS the projectFile/entryPoint.  Spawning new nimsuggest for this.", uri = uri, entryPoint = spawnInfo.entryPoint
        discard await createSlotWithFallback(ls, spawnInfo, filePath, q.didOpen.textDocument)

      else:
        # File is part of a project whose entry point is a different file.
        debug "didOpen: It is PART of a module and has a projectFile/entryPoint (not itself)", uri = uri, entryPoint = spawnInfo.entryPoint
        let existingModuleSlot = ls.pool.slots.getOrDefault(spawnInfo.entryPoint)
        if existingModuleSlot != nil and existingModuleSlot.state == SlotState.READY:
          # Module slot is fully live — assign directly; consolidation already ran.
          debug "didOpen: Module slot is READY, assigning uri to it", uri = uri, entryPoint = spawnInfo.entryPoint
          ls.addFileToOpenFiles(existingModuleSlot, q.didOpen.textDocument)
        else:
          # No module slot, or it is still SPAWNING in the background.
          # Give this file its own immediate file-based slot rather than waiting.
          debug "didOpen: Spawning file-based slot immediately", entryPoint = spawnInfo.entryPoint, uri = uri
          let spawnResult = await createSlotWithFallback(ls, spawnInfo, filePath, q.didOpen.textDocument)
          if spawnResult.isSome():
            debug "didOpen: Successfully spawned a new nimsuggest slot", entryPoint = spawnInfo.entryPoint, uri = uri

            let dirtyFile = uriToStashFilePath(ls.files.storageDir, uri)

            let query = NimsuggestQuery[LspFilePosition](
              kind: NimsuggestQueryKind.CHECK_FILE,
              isDependency: false,
              uri: uri,
              dirtyFile: dirtyFile,
              responseFuture: newFuture[seq[Suggest]]("queryFile"),
            )
            let spawnedSlot = spawnResult.get()
            spawnedSlot.queryMailbox.addLastNoWait(query)


          else:
            debug "didOpen: Spawning was NOT successful.", entryPoint = spawnInfo.entryPoint

    # If no spawn path added the file to openFiles, add it now with no slot.
    # Without this, every DID_CHANGE generates a synthetic DID_OPEN that retries
    # the (doomed) spawn indefinitely.
    if uri notin ls.files.openFiles:
      discard writeStashFile(ls.files.storageDir, uri, q.didOpen.textDocument.text)
      ls.files.openFiles[uri] = initNlsFileInfo(q.didOpen.textDocument)

    let needToEvict = ls.pool.maxSlots > 0 and ls.pool.slots.len > ls.pool.maxSlots      
    debug "didOpen: Should slot be evicted?", maxSlots = ls.pool.maxSlots, filledSlots = ls.pool.slots.len, needToEvict = needToEvict
    if needToEvict:
      let slotToEvict = nimsuggestSlotToEvict(ls.pool)
      debug "didOpen: Evicting a slot.", slotToEvict = slotToEvict.spawnInfo.entryPoint
      while slotToEvict.queryMailbox.len > 0:
        let pendingQ = slotToEvict.queryMailbox.popFirstNoWait()
        if not pendingQ.responseFuture.finished:
          pendingQ.responseFuture.complete(@[])

      debug "didOpen: Stopping and removing from slot: ", entryPoint = slotToEvict.spawnInfo.entryPoint
      discard await stopNimsuggestSlotAndRemoveFromPool(ls.pool, slotToEvict)


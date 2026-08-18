import std/[options, sets, tables, sequtils, strutils]
import chronos
import chronicles
import ../nimsuggest/nimsuggest
import ../nimble/nimble_utils
import ../protocol/types
import ../utils/utils
import ./[langserver_types, query_types]
import ./[dispatcher_utils, langserver_utils]

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
      newSlot.ownedUris.incl(toUri(oldSlot.spawnInfo.entryPoint))

      if toUri(oldSlot.spawnInfo.entryPoint) in ls.files.openFiles:
        ls.files.openFiles[toUri(oldSlot.spawnInfo.entryPoint)].slot = newSlot

      for oldSlotUri in oldSlot.ownedUris.toSeq:
        debug "consolidateNimsuggestInstances: reassign owned uri ", oldSlotUri = oldSlotUri
        
        oldSlot.ownedUris.excl(oldSlotUri)
        newSlot.ownedUris.incl(oldSlotUri)
        if oldSlotUri in ls.files.openFiles:
          ls.files.openFiles[oldSlotUri].slot = newSlot

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
    ls.configurations.currentConfig,
    ls.notify,
  )
  discard await ls.consolidateNimsuggestInstances(slot)

proc attemptModuleSpawnInBackground(
  ls: LanguageServer,
  spawnInfo: NimsuggestSpawnInfo,
) {.async.} =
  ## Attempts to spawn nimsuggest with the full module entry point in the
  ## background. If it succeeds, consolidateNimsuggestInstances migrates all
  ## file-based slots to the module slot. If it fails, the entry point is added
  ## to pool.crashedSlots so subsequent opens skip the background attempt.
  debug "attemptModuleSpawnInBackground: starting",
    entryPoint = spawnInfo.entryPoint
  let moduleSlot = await spawnNewNimsuggestSlot(
    ls.pool, spawnInfo, ls.pool.nimsuggest, ls.configurations.currentConfig)

  if moduleSlot.isNone:
    warn "attemptModuleSpawnInBackground: failed, adding to crashedSlots",
      entryPoint = spawnInfo.entryPoint
    ls.pool.crashedSlots.incl(spawnInfo.entryPoint)
    return

  info "attemptModuleSpawnInBackground: succeeded, consolidating",
    entryPoint = spawnInfo.entryPoint
  asyncSpawn moduleSlot.get().processNimsuggestQueries(
    ls.pool, ls.files.openFiles, ls.dependencies,
    ls.configurations.currentConfig, ls.notify)
  discard await ls.consolidateNimsuggestInstances(moduleSlot.get())

proc createSlotWithFallback(
  ls: LanguageServer,
  spawnInfo: NimsuggestSpawnInfo,
  filePath: FilePathAbs,
  params: TextDocumentItem,
): Future[Option[NimsuggestSlot]] {.async.} =
  ## Tier 1 (immediate): spawn nimsuggest with filePath as entry point and the
  ## nimble dir as workingDir. This picks up config.nims path resolution without
  ## touching the (potentially broken) module entry point. Fast (~10s).
  ##
  ## Tier 2 (background): if filePath != module entry point, asyncSpawn an
  ## attempt at the module entry point for richer project context. On success,
  ## consolidateNimsuggestInstances migrates all file-based slots automatically.
  ## On failure, the entry point is added to pool.crashedSlots.
  let nimbleDir = parentDir(spawnInfo.nimbleFile.get())
  let fileInfo = NimsuggestSpawnInfo(
    entryPoint: filePath,
    workingDir: nimbleDir,
    nimbleFile: spawnInfo.nimbleFile,
    paths: @[],
    extraArgs: @[],
  )
  let slot = await spawnNewNimsuggestSlot(
    ls.pool, fileInfo, ls.pool.nimsuggest, ls.configurations.currentConfig)

  if slot.isNone:
    return none(NimsuggestSlot)

  await ls.startSlotConsumer(slot.get(), params)

  # Background: attempt the real module entry point for full project context.
  # Only if the opened file is not itself the module entry point, the entry
  # point is not known-broken, and no background spawn is already running.
  if filePath != spawnInfo.entryPoint and
     spawnInfo.entryPoint notin ls.pool.crashedSlots and
     not ls.pool.slots.hasKey(spawnInfo.entryPoint):
    asyncSpawn ls.attemptModuleSpawnInBackground(spawnInfo)

  return slot

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
    let slot = ls.files.openFiles[uri].slot
    case slot.state 
    of SlotState.READY, SlotState.SPAWNING:
      if uri in slot.ownedUris:
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
      dirtyFile: ls.uriToStash(uri),  # or should this be empty?
      responseFuture: newFuture[seq[Suggest]]("checkFile"),
    ))
    # Finished
  else:
    # This file is not known by any running nimsuggest instance.
    # Check there is a free nimsuggest slot
    let filePath = toFilePathAbs(uri)

    # Nimsuggest only accepts .nim files as entry points. Skip spawn for
    # .nimble, .nims, and any other non-.nim files — they are not compilable
    # by nimsuggest and will crash it with "command expects a filename".
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
            discard ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)
          else:
            debug "didOpen: Spawning was NOT successful.", entryPoint = spawnInfo.entryPoint

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


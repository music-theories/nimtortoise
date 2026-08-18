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

proc createNewSuggestSlotAndConsolidate(
  ls: LanguageServer,
  filePath: FilePathAbs,
  params: TextDocumentItem
): Future[Option[NimsuggestSlot]] {.async.} =
  let successfulSpawn = await spawnNewNimsuggestSlot(
    ls.pool, 
    filePath, 
    ls.files.rootPath, 
    ls.pool.nimsuggest,
    ls.dependencies,
    ls.configurations.currentConfig
  )
  if successfulSpawn.isSome():
    debug "createNewSuggestSlotAndConsolidate:add file to open files", filePath = $(filePath)
    let spawnedSlot = successfulSpawn.get()
    ls.addFileToOpenFiles(spawnedSlot, params)
    asyncSpawn spawnedSlot.processNimsuggestQueries(
      ls.pool, 
      ls.files.openFiles,
      ls.dependencies,
      ls.configurations.currentConfig,
      ls.notify,
    )
    # Consolidation: for each other slot, check if the new slot subsumes it.
    discard await ls.consolidateNimsuggestInstances(spawnedSlot)
  
  return successfulSpawn

proc createNewSuggestSlotAndConsolidate(
  ls: LanguageServer,
  spawnInfo: NimsuggestSpawnInfo,
  params: TextDocumentItem
): Future[Option[NimsuggestSlot]] {.async.} =
  let successfulSpawn = await spawnNewNimsuggestSlot(
    ls.pool, 
    spawnInfo,
    ls.pool.nimsuggest,
    ls.configurations.currentConfig
  )
  if successfulSpawn.isSome():
    debug "createNewSuggestSlotAndConsolidate:add file to open files", entryPoint = spawnInfo.entryPoint
    let spawnedSlot = successfulSpawn.get()
    ls.addFileToOpenFiles(spawnedSlot, params)
    asyncSpawn spawnedSlot.processNimsuggestQueries(
      ls.pool, 
      ls.files.openFiles,
      ls.dependencies,
      ls.configurations.currentConfig,
      ls.notify,
    )
    # Consolidation: for each other slot, check if the new slot subsumes it.
    discard await ls.consolidateNimsuggestInstances(spawnedSlot)
  
  return successfulSpawn
    

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
      discard await createNewSuggestSlotAndConsolidate(
        ls, filePath, q.didOpen.textDocument
      )
    
    else:
      if spawnInfo.entryPoint == filePath:
        debug "didOpen: This uri IS the projectFile/entryPoint.  Spawning new nimsuggest for this.", uri = uri, entryPoint = spawnInfo.entryPoint
        # Importantly, we've already checked if this uri is known, so we're just now checking if it knows any other nimsuggest instances that can be consolidated into it.
        discard await createNewSuggestSlotAndConsolidate(ls, spawnInfo, q.didOpen.textDocument)

      else:
        # File maps to a specific project entry point (via projectMapping regex) TODO - no longer using prejectMapping ... Would this branch even be possible ...
        debug "didOpen: It is PART of a module and has a projectFile/entryPoint (not itself)", uri = uri, entryPoint = spawnInfo.entryPoint
        if ls.pool.slots.hasKey(spawnInfo.entryPoint):
          debug "didOpen: Nimsuggest slot for the projectFile/entryPoint already running, assigning the uri to this slot", uri = uri, entryPoint = spawnInfo.entryPoint
          ls.addFileToOpenFiles(ls.pool.slots[spawnInfo.entryPoint], q.didOpen.textDocument)
          
        else:
          debug "didOpen: The uri's projectFile/entryPoint does not have a nimsuggest slot, so spawn it ", entryPoint = spawnInfo.entryPoint
          let slotSpawnSuccessful = await spawnNewNimsuggestSlot(
            ls.pool, spawnInfo, 
            ls.pool.nimsuggest, 
            ls.configurations.currentConfig
          )
          if slotSpawnSuccessful.isSome():
            # Starts mailbox
            let newSlot = slotSpawnSuccessful.get()

            asyncSpawn processNimsuggestQueries(
              newSlot, ls.pool, ls.files.openFiles,
              ls.dependencies,
              ls.configurations.currentConfig,
              ls.notify,
            )
            debug "didOpen: Successfully spawned a new nimsuggest slot ", entryPoint = spawnInfo.entryPoint, uri = uri

            ls.addFileToOpenFiles(newSlot, q.didOpen.textDocument)
            discard await ls.consolidateNimsuggestInstances(newSlot)
            discard ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)

            # debug "didOpen: Ensure the projectFile/entryPoint ACTUALLY knows the uri ", entryPoint = spawnInfo.entryPoint

            # let projectKnownQuery = NimsuggestQuery[LspFilePosition](
            #   id: 0.uint,
            #   kind: NimsuggestQueryKind.KNOWN,
            #   uri: uri,
            #   dirtyFile: FilePathAbs(""),
            #   responseFuture: newFuture[seq[Suggest]]("known"),
            # )
            # newSlot.queryMailbox.addLastNoWait(projectKnownQuery)

            # let projectResponse = await projectKnownQuery.responseFuture

            # let thisProjectKnowsTheFile = checkNimsuggestKnownResponse(projectResponse)

            # if thisProjectKnowsTheFile:
            #   debug "didOpen: The project DOES know the uri.", fileThatKnows = newSlot.spawnInfo.entryPoint,  fileThatIsKnown = uri
            #   ls.addFileToOpenFiles(newSlot, q.didOpen.textDocument)
            #   discard await ls.consolidateNimsuggestInstances(newSlot)
            #   discard ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)

            # else:
            #   debug "didOpen: The project does NOT know the current file.  This means it is within the module's folders but not connected to it. It is an orphan.  Spin up a new standalone nimsuggest for it."
            #   # v4 unknown-file workaround: nimsuggest compiled the project entry point
            #   # but won't index files it hasn't served yet — queries return length=0.
            #   # Use filePath (the opened file) as the standalone entry point, not the
            #   # project entry point, so nimsuggest compiles it directly.
            #   discard await stopNimsuggestSlotAndRemoveFromPool(ls.pool, newSlot)
            #   discard await createNewSuggestSlotAndConsolidate(
            #     ls, filePath, q.didOpen.textDocument
            #   )
          else:
            debug "didOpen: Spawning projectFile/entryPoint was NOT successful.", entryPoint = spawnInfo.entryPoint
            ls.pool.removeSlot(spawnInfo.entryPoint)

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
      let successfulStop = await stopNimsuggestSlotAndRemoveFromPool(ls.pool, slotToEvict)


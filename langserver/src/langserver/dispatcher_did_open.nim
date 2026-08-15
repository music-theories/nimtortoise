import std/[options, sets, tables, sequtils]
import chronos
import chronicles
import ../nimsuggest/nimsuggest
import ../nimble/nimble_utils
import ../protocol/types
import ../utils/utils
import ./[langserver_types, query_types]
import ./[dispatcher_utils, langserver_utils, langserver_nimsuggest]

proc consolidateNimsuggestInstances(
  ls: LanguageServer,
  newSlot: NimsuggestSlot,
): Future[seq[FilePath]] {.async.} =
  # Consolidation: for each other slot, check if the new slot subsumes it.
  var slotsToRemove: seq[FilePath] = @[]
  for projectPath, oldSlot in ls.pool.slots:
    if oldSlot.projectFile == newSlot.projectFile: continue
    let knownQuery = NimsuggestQuery[LspFilePosition](
      id: 0.uint,
      kind: NimsuggestQueryKind.KNOWN,
      uri: pathToUri(oldSlot.projectFile),
      dirtyFile: FilePath(""),
      responseFuture: newFuture[seq[Suggest]]("known"),
    )
    newSlot.queryMailbox.addLastNoWait(knownQuery)
    let response = await knownQuery.responseFuture
    let newSlotKnowsOldSlot = checkNimsuggestKnownResponse(response)

    if newSlotKnowsOldSlot:
      debug "consolidateNimsuggestInstances: new slot knows old slot", newSlotProjectFile = newSlot.projectFile, oldSlotProjectFile = oldSlot.projectFile
      # New slot knows old slot's entry point → it imported old slot entirely.
      # Transfer all owned URIs and shut the old slot down.
      newSlot.ownedUris.incl(pathToUri(oldSlot.projectFile))

      if pathToUri(oldSlot.projectFile) in ls.files.openFiles:
        ls.files.openFiles[pathToUri(oldSlot.projectFile)].slot = newSlot

      for oldSlotUri in oldSlot.ownedUris.toSeq:
        debug "consolidateNimsuggestInstances: reassign owned uri ", oldSlotUri = oldSlotUri
        
        oldSlot.ownedUris.excl(oldSlotUri)
        newSlot.ownedUris.incl(oldSlotUri)
        if oldSlotUri in ls.files.openFiles:
          ls.files.openFiles[oldSlotUri].slot = newSlot


      discard await execStop(oldSlot, ls.pool)
      slotsToRemove.add(oldSlot.projectFile)
    else:
      debug "consolidateNimsuggestInstances: new slot does not know old slot", newSlotProjectFile = newSlot.projectFile, oldSlotProjectFile = oldSlot.projectFile

  debug "consolidateNimsuggestInstances: remove slots", slotsToRemove = slotsToRemove
  for s in slotsToRemove:
    ls.pool.removeSlot(s)
  
  return slotsToRemove

proc createNewSuggestSlotAndConsolidate(
  ls: LanguageServer,
  filePath: FilePath,
  params: TextDocumentItem
): Future[NimsuggestSlot] {.async.} =

  let workingDir = getWorkingDir(ls.files.rootPath, filePath, ls.configurations.currentConfig)
  let newSlot = newSlot(filePath, isEntryPoint = true, workingDir)
  ls.pool.addSlot(newSlot)
  debug "createNewSuggestSlotAndConsolidate: spawn new nimsuggest slot", workingDir = workingDir
  let successfulSpawn = await execSpawn(newSlot, ls.pool, filePath, ls.configurations.currentConfig)
  if successfulSpawn:
    debug "createNewSuggestSlotAndConsolidate:add file to open files", filePath = $(filePath)
    ls.addFileToOpenFiles(newSlot, params)
    asyncSpawn processNimsuggestQueries(
      newSlot, ls.pool, ls.files.openFiles, 
      ls.configurations.currentConfig,
      ls.notify
    )
    # Consolidation: for each other slot, check if the new slot subsumes it.
    discard await ls.consolidateNimsuggestInstances(newSlot)
    
  else:
    debug "createNewSuggestSlotAndConsolidate: spawn unsuccessful"
    ls.pool.removeSlot(filePath)
  return newSlot

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
    let filePath: FilePath = uriToPath(uri)

    debug "didOpen: Check if it has a projectFile/entryPoint.  i.e. Is a true orphan?", uri = uri, filePath = filePath
    # does it have a project file?
    let intendedProjectPath: FilePath = getEntryPointFromProjectMapping(
      ls.files.rootPath, 
      uri,
      ls.configurations.currentConfig
    )
    let hasProjectFile = string(intendedProjectPath) != ""

    if hasProjectFile == false:
      debug "didOpen: File has no projectFile.  It is a true orphan. Spawning standalone nimsuggest for it.", entryPoint = filePath
      discard await createNewSuggestSlotAndConsolidate(ls, filePath, q.didOpen.textDocument)
    
    else:
      if intendedProjectPath == filePath:
        debug "didOpen: This uri IS the projectFile/entryPoint.  Spawning new nimsuggest for this.", uri = uri, intendedProjectPath = intendedProjectPath
        # Importantly, we've already checked if this uri is known, so we're just now checking if it knows any other nimsuggest instances that can be consolidated into it.
        discard await createNewSuggestSlotAndConsolidate(ls, filePath, q.didOpen.textDocument)

      else:
        # File maps to a specific project entry point (via projectMapping regex).
        debug "didOpen: It is PART of a module and has a projectFile/entryPoint (not itself)", uri = uri, projectFile = intendedProjectPath
        if ls.pool.slots.hasKey(intendedProjectPath):
          debug "didOpen: Nimsuggest slot for the projectFile/entryPoint already running, assigning the uri to this slot", uri = uri, projectFile = intendedProjectPath
          # if uri in ls.files.openFiles:
          ls.addFileToOpenFiles(ls.pool.slots[intendedProjectPath], q.didOpen.textDocument)
          
        else:
          debug "didOpen: The uri's projectFile/entryPoint does not have a nimsuggest slot, so spawn it ", projectFile = intendedProjectPath
          let projectWorkingDir = getWorkingDir(
            ls.files.rootPath,
            intendedProjectPath,
            ls.configurations.currentConfig
          )
          let newProjectSlot = newSlot(
            intendedProjectPath,
            isEntryPoint = true,
            workingDir = projectWorkingDir
          )
          ls.pool.addSlot(newProjectSlot)
          let intendedProjectSpawn = await execSpawn(newProjectSlot, ls.pool, intendedProjectPath, ls.configurations.currentConfig)
          if intendedProjectSpawn:
            # Starts mailbox
            asyncSpawn processNimsuggestQueries(
              newProjectSlot, ls.pool, ls.files.openFiles, 
              ls.configurations.currentConfig,
              ls.notify
            )
            debug "didOpen: Ensure the projectFile/entryPoint ACTUALLY knows the uri ", projectFile = intendedProjectPath
            let projectKnownQuery = NimsuggestQuery[LspFilePosition](
              id: 0.uint,
              kind: NimsuggestQueryKind.KNOWN,
              uri: uri,
              dirtyFile: FilePath(""),
              responseFuture: newFuture[seq[Suggest]]("known"),
            )
            newProjectSlot.queryMailbox.addLastNoWait(projectKnownQuery)
            let projectResponse = await projectKnownQuery.responseFuture
            let thisProjectKnowsTheFile = checkNimsuggestKnownResponse(projectResponse)
            if thisProjectKnowsTheFile:
              debug "didOpen: The project does know the uri.", fileThatKnows = intendedProjectPath,  fileThatIsKnown = uri
              ls.addFileToOpenFiles(newProjectSlot, q.didOpen.textDocument)
              discard await ls.consolidateNimsuggestInstances(newProjectSlot)
              discard ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)
            else:
              debug "didOpen: The project does not know the current file.  This means it is within the module's folders but not connected to it. It is an orphan.  Spin up a new standalone nimsuggest for it."
              discard await execStop(newProjectSlot, ls.pool)
              ls.pool.removeSlot(intendedProjectPath)
              discard await createNewSuggestSlotAndConsolidate(ls, filePath, q.didOpen.textDocument)
          else:
            debug "didOpen: Spawning projectFile/entryPoint was unsuccessful.", intendedProjectPath = intendedProjectPath
            ls.pool.removeSlot(intendedProjectPath)

    let needToEvict = ls.pool.maxSlots > 0 and ls.pool.slots.len > ls.pool.maxSlots      
    debug "didOpen: Should slot be evicted?", maxSlots = ls.pool.maxSlots, filledSlots = ls.pool.slots.len, needToEvict = needToEvict
    if needToEvict:
      let slotToEvict = nimsuggestSlotToEvict(ls.pool)
      debug "didOpen: Evicting a slot.", slotToEvict = slotToEvict.projectFile
      while slotToEvict.queryMailbox.len > 0:
        let pendingQ = slotToEvict.queryMailbox.popFirstNoWait()
        if not pendingQ.responseFuture.finished:
          pendingQ.responseFuture.complete(@[])

      let successfulStop = await execStop(slotToEvict, ls.pool)
      if successfulStop:
        debug "didOpen: Removing from slot: ", projectFile = slotToEvict.projectFile
        ls.pool.removeSlot(slotToEvict.projectFile)

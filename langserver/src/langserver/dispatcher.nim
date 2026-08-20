import std/[options, sets, strutils, tables, os, json]
import chronos
import chronicles
import ../nph/formatting
import ../nimsuggest/nimsuggest

import ../configurations/configurations
import ../nimble/nimble_utils
import ../protocol/types

import ../utils/utils
import ./[langserver_types, query_types, langserver_utils, capability_configs]
import ./[dispatcher_did_open, dispatcher_did_change]


proc waitForLsInitialized*(ls: LanguageServer): Future[void] {.async.} =
  ## Waits until initNimsuggestInstances has completed (config received, nimble dump
  ## done, entry-point slots spawned), with a 60-second timeout.
  ## Uses polling so a timeout does not cancel the shared lsInitialized future.
  if ls.lsInitialized.finished:
    return
  debug "waitForLsInitialized: waiting for ls initialization (initNimsuggestInstances not yet done)"
  var elapsed = 0
  # TODO - NOTE - Should this 60-second-limit be a constant or in the configurations?
  while not ls.lsInitialized.finished and elapsed < 60_000:
    await sleepAsync(100)
    inc elapsed, 100

  if not ls.lsInitialized.finished:
    warn "initNimsuggestInstances did not complete within timeout; proceeding anyway"

proc processLangserverQueue*(ls: LanguageServer): Future[void] {.async.} =
  ## Single coroutine that drains ls.langserverQueue in FIFO order.
  ##
  ## All LSP-triggered work — file operations and nimsuggest queries alike —
  ## flows through this queue. Processing order matches LSP message arrival
  ## order, guaranteeing that a didChange stash write is applied before any
  ## subsequent hover query is dispatched to the per-slot mailbox.
  ##
  ## Invariant: use `while true` not tail recursion. Each recursive async call
  ## creates a new Future object that is never freed until the chain resolves
  ## (which for an infinite loop means never), corrupting the heap under ORC.
  while true:
    debug "processLangserverQueue: waiting for next item", queueLen = ls.langserverQueue.len
    let query = await ls.langserverQueue.popFirst()
    # Wait for initNimsuggestInstances to complete so that:
    # (a) config is available for getIntendedProject, and
    # (b) entry-point slots are in the pool so we can assign to them.
    await ls.waitForLsInitialized()
    # TODO: Check all paths through the dispatcher result in any pending futures being completed.
    debug "processLangserverQueue: dequeued item", kind = $query.kind
    case query.kind
    of LangserverQueryKind.SHUTDOWN:
      await ls.pool.stopAllNimsuggestSlotsInPool()
      query.shutdown.complete(true)
      ls.isShutdown = true
      return 
    of LangserverQueryKind.NIMSUGGEST:
      let q = query.nimsuggest
      # Refresh dirtyFile at dispatch time. The query was constructed in the LSP
      # handler before any FILE_ACCESS (DID_CHANGE) in front of it was processed,
      # so dirtyFile may have been captured as "" even though changed=true by now.
      # if q.kind == NimsuggestQueryKind.CHANGED and q.saved:
      #   q.dirtyFile = FilePathAbs("")
      # else:
      q.dirtyFile = ls.uriToStash(q.uri)

      # First, check if the current file is owned by a nimsuggest instance
      let path = toFilePathAbs(q.uri)
      if q.uri in ls.files.openFiles:
        let fileInfo = ls.files.openFiles[q.uri]
        # If a slot is stopped, crashed or stopping, do not attempt to restart - this should happen when a user saves, open changes a file - otherwise any random dragging a mouse across a file would cause a restart. 
        # TODO/NOTE: Is KNOWN treated correctly?
        case fileInfo.slot.state
        of SlotState.READY, SlotState.SPAWNING:
          debug "processLangserverQueue: dispatcher adding message to slot mailbox", uri = q.uri, kind = $q.kind, fileInfoIsNil = (fileInfo == nil), entryPoint = fileInfo.slot.spawnInfo.entryPoint

          fileInfo.slot.queryMailbox.addLastNoWait(q)

        of SlotState.STOPPING, SlotState.STOPPED, SlotState.CRASHED:
          debug "processLangserverQueue: slot is inactive", uri = q.uri, state = fileInfo.slot.state
          if not q.responseFuture.finished:
            q.responseFuture.complete(@[])
          continue

      elif path in ls.pool.slots:
        let slot = ls.pool.slots[path]
        case slot.state
        of SlotState.READY, SlotState.SPAWNING:
          debug "processLangserverQueue: Add path-level query to mailbox. ", uri = q.uri, kind = $q.kind
          ls.pool.slots[path].queryMailbox.addLastNoWait(q)
        else:
          debug "processLangserverQueue: Could not add path-level message to mailbox. Slot is not live.", uri = q.uri, kind = $q.kind
          q.responseFuture.complete(@[])

      else:
        debug "processLangserverQueue: Could not add message to mailbox", uri = q.uri, kind = $q.kind
        q.responseFuture.complete(@[])

    of LangserverQueryKind.FILE_ACCESS:
      let q = query.fileAccess
      case q.kind
      of FileAccessQueryKind.DID_OPEN:
        await ls.processDidOpenQuery(q)
            
      of FileAccessQueryKind.DID_CHANGE:
        await ls.processDidChangeQuery(q)

      of FileAccessQueryKind.DID_SAVE:
        let uri = q.didSave.textDocument.uri
        debug "didSave: file", uri = uri
        if uri in ls.files.openFiles:
          let fileInfo = ls.files.openFiles[uri]
          if uri in fileInfo.slot.crashedUris:
            fileInfo.slot.crashedUris.excl(uri)

          if q.didSave.text.isSome:
            let stashLocation = ls.uriStorageLocation(uri)
            let file = open(string(stashLocation), fmWrite)
            fileInfo.fingerTable = @[]
            for line in q.didSave.text.get.splitLines:
              fileInfo.fingerTable.add(line.createUTFMapping())
              file.writeLine(line)
            file.close()

          debug "didSave: sending CHANGED query", uri = uri
          # Directly query nimsuggest
          case fileInfo.slot.state
          of SlotState.READY, SlotState.SPAWNING:
            let changedQuery = NimsuggestQuery[LspFilePosition](
              id: 0,
              kind: NimsuggestQueryKind.CHANGED,
              uri: uri,
              dirtyFile: ls.uriStorageLocation(uri),
              saved: true,
              responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
            )
            fileInfo.slot.queryMailbox.addLastNoWait(changedQuery)

            # if ls.configurations.currentConfig.checkOnSave:
            #   debug "Checking project", uri = uri
            #   let chkQuery = NimsuggestQuery[LspFilePosition](
            #     id: 0,
            #     kind: NimsuggestQueryKind.CHECK_PROJECT,
            #     uri: toUri(fileInfo.slot.spawnInfo.entryPoint),
            #     dirtyFile: ls.uriStorageLocation(uri), # FilePathAbs(""),
            #     responseFuture: newFuture[seq[Suggest]]("checkProject"),
            #   )
            #   fileInfo.slot.queryMailbox.addLastNoWait(chkQuery)
          
          of SlotState.STOPPING, SlotState.STOPPED, SlotState.CRASHED:
            discard

          # Clear this file's module entry point from crashedSlots — the user
          # may have fixed the underlying compiler issue (e.g. removed a
          # problematic import), so give the background spawn another chance.
          let savedFilePath = toFilePathAbs(uri)
          let savedSpawnInfo = getNimsuggestSpawnInfo(
            savedFilePath, ls.files.rootPath, ls.dependencies)
          if savedSpawnInfo.entryPoint != savedFilePath and
             savedSpawnInfo.entryPoint in ls.pool.crashedSlots:
            debug "didSave: clearing crashedSlots for module entry point",
              entryPoint = savedSpawnInfo.entryPoint
            ls.pool.crashedSlots.excl(savedSpawnInfo.entryPoint)

      of FileAccessQueryKind.DID_CLOSE:
        let uri = q.didClose.textDocument.uri
        debug "Closed the following document:", uri = uri
        if uri notin ls.files.openFiles:
          continue
        let fileInfo = ls.files.openFiles[uri]
        fileInfo.slot.unassignUri(uri)
        # If the slot has no remaining tracked files, shut it down — important for standalone orphan slots.
        debug "Check the amount of owned uris for this slot:", uri = uri, ownedUris = fileInfo.slot.ownedUris.len
        if fileInfo.slot.ownedUris.len == 0 and ls.pool.slots.len > 1:
          # The ls.pool.slots.len > 1 qualification means that if there is only one slot left, it is persisted, so nimsuggest is not constantly spawning and stopping.
          debug "Stopping this slot:", uri = uri
          discard await stopNimsuggestSlotAndRemoveFromPool(ls.pool, fileInfo.slot)
          ls.pool.removeSlot(fileInfo.slot.spawnInfo.entryPoint)
        ls.files.openFiles.del(uri)

      of FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL:
        let uri = q.willSave.textDocument.uri
        let config = ls.configurations.currentConfig
        let nphPath = getNphPath()

        let shouldFormat =
          nphPath.isSome and ls.capabilities.lspServerCapabilities.documentFormattingProvider.get(false) and
          config.formatOnSave

        if shouldFormat:
          debug "Formatting document before save", uri = uri
          # THis runs the formatting 
          let formatTextEdit = await format(ls, nphPath.get(), uri)
          if formatTextEdit.isSome:
            q.willSaveResponse.complete(@[formatTextEdit.get])
          else:
            q.willSaveResponse.complete(@[])
        else:
          q.willSaveResponse.complete(@[])

      of FileAccessQueryKind.DID_RENAME_FILES:
        for r in q.renameFiles.files:
          let oldUri = r.oldUri
          let newUri = r.newUri
          debug "File renamed", oldUri = oldUri, newUri = newUri
          let oldStash = ls.uriStorageLocation(oldUri)
          let newStash = ls.uriStorageLocation(newUri)
          let oldPath = toFilePathAbs(oldUri)
          let newPath = toFilePathAbs(newUri)

          if string(oldStash).fileExists:
            try:
              moveFile(string(oldStash), string(newStash))
            except Exception as e:
              debug "Failed to move stash file on rename",
                oldStash = oldStash, newStash = newStash, msg = e.msg

          # TODO - need to update this and also ensure dependencies are recalculated.
          # if string(oldPath).endsWith(".nimble"):
          #   ls.nimbleDumpCache.del(oldPath)
          #   ls.nimbleDumpCache.del(toFilePathAbs(newUri))

          if oldUri in ls.files.openFiles:
            let fileInfo = ls.files.openFiles[oldUri]
            let slot = fileInfo.slot
            slot.unassignUri(oldUri)
            slot.assignUri(newUri)
            ls.files.openFiles[newUri] = NlsFileInfo(
              slot: slot,
              fingerTable: fileInfo.fingerTable,
              lastChanged: fileInfo.lastChanged,
              lastChecked: fileInfo.lastChecked,
              textDocument: TextDocumentItem(
                uri: newUri,
                languageId: fileInfo.textDocument.languageId,
                version: fileInfo.textDocument.version,
                text: fileInfo.textDocument.text,
              ),
            )
            ls.files.openFiles.del(oldUri)

            if string(newPath).endsWith(".nim"):
              # RECOMPILE The Nimsuggest Instance
              debug "processCommands: sending recompile", entryPoints = slot.spawnInfo.entryPoint
              let recompileQuery = NimsuggestQuery[LspFilePosition](
                kind: NimsuggestQueryKind.RECOMPILE,
                uri: toUri(slot.spawnInfo.entryPoint),
                dirtyFile: FilePathAbs(""),
                responseFuture: newFuture[seq[Suggest]]("recompile"),
              )
              slot.queryMailbox.addLastNoWait(recompileQuery)

      of FileAccessQueryKind.DID_DELETE_FILES:
        for f in q.deleteFiles.files:
          let uri = f.uri
          debug "File deleted", uri = uri
          let path = toFilePathAbs(uri)
          # TODO 
          # if string(path).endsWith(".nimble"):
          #   ls.nimbleDumpCache.del(path)

          if uri in ls.files.openFiles:
            let fileInfo = ls.files.openFiles[uri]
            fileInfo.slot.unassignUri(uri)
            ls.files.openFiles.del(uri)

            if string(path).endsWith(".nim"):
              let recompileQuery = NimsuggestQuery[LspFilePosition](
                kind: NimsuggestQueryKind.RECOMPILE,
                uri: toUri(fileInfo.slot.spawnInfo.entryPoint),
                dirtyFile: FilePathAbs(""),
                responseFuture: newFuture[seq[Suggest]]("recompile"),
              )
              fileInfo.slot.queryMailbox.addLastNoWait(recompileQuery)

      of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
        debug "Changed configuration: "
        var receivedConfigJson: JsonNode
        if ls.usePullConfigurationModel():
          if ls.supportsConfigurationRequest():
            debug "Requesting configuration from the client"
            let configurationParams = %*{"items": [{"section": "nimTortoise"}]}
            let configFuture = ls.call("workspace/configuration", configurationParams)
            receivedConfigJson = await configFuture 
          else:
            debug "Client does not support workspace/configuration"
            ls.configurations.configReady.fire()
            continue
        else:
          receivedConfigJson = q.didChangeConfiguration
        
        let oldConfiguration = ls.configurations.currentConfig
        let newConfiguration = parseDidChangeConfiguration(receivedConfigJson)

        let newConfigurationIsDifferent = isDifferentFrom(newConfiguration, oldConfiguration)

        if newConfigurationIsDifferent:
          ls.configurations.currentConfig = newConfiguration

        ls.configurations.configReady.fire()

      of FileAccessQueryKind.FORMATTING:
        let uri = q.formatting.textDocument.uri
        let nphPath = getNphPath()
        if nphPath.isSome:
          let formatTextEdit = await format(ls, nphPath.get(), uri)
          if formatTextEdit.isSome:
            q.formattingResponse.complete(@[formatTextEdit.get])
          else:
            q.formattingResponse.complete(@[])
        else:
          q.formattingResponse.complete(@[])

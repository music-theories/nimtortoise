import std/[options, sets, strutils, tables, json]
import chronos
import chronicles

import forest

import ../nph/formatting
import ../nimsuggest/nimsuggest

import ../configurations/configurations
import ../protocol/types

import ../utils/utils
import ./[langserver_types, query_types, capability_configs]
import ./[dispatcher_did_open, dispatcher_did_change, dispatcher_did_save, dispatcher_did_close, dispatcher_did_rename, dispatcher_did_delete]

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
  var saveCounter = 0
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

    of LangserverQueryKind.RESTART:
      await ls.pool.stopAllNimsuggestSlotsAndRemoveFromPool()
      ls.pool.crashedSlots.clear()
      ls.dependencies = await initForest(ls.files.rootPath)
      query.restart.complete(true)


    of LangserverQueryKind.NIMSUGGEST:
      let q = query.nimsuggest
      # Refresh dirtyFile at dispatch time. The query was constructed in the LSP
      # handler before any FILE_ACCESS (DID_CHANGE) in front of it was processed,
      # so dirtyFile may have been captured as "" even though changed=true by now.
      # if q.kind == NimsuggestQueryKind.CHANGED and q.saved:
      #   q.dirtyFile = FilePathAbs("")
      # else:
      q.dirtyFile = uriToStashFilePath(ls.files.storageDir, q.uri)

      # First, check if the current file is owned by a nimsuggest instance
      let path = toFilePathAbs(q.uri)
      if q.uri in ls.files.openFiles:
        let fileInfo = ls.files.openFiles[q.uri]

        let slotCheck = getSlotThatOwnsUri(ls.pool, q.uri)
        if slotCheck.isSome():
          let slotThatOwnsUri = slotCheck.get()
          
          # If a slot is stopped, crashed or stopping, do not attempt to restart - this should happen when a user saves, open changes a file - otherwise any random dragging a mouse across a file would cause a restart. 
          # TODO/NOTE: Is KNOWN treated correctly?
          case slotThatOwnsUri.state
          of SlotState.READY, SlotState.SPAWNING:
            debug "processLangserverQueue: dispatcher adding message to slot mailbox", uri = q.uri, kind = $q.kind, fileInfoIsNil = (fileInfo == nil), entryPoint = slotThatOwnsUri.spawnInfo.entryPoint

            slotThatOwnsUri.queryMailbox.addLastNoWait(q)

          of SlotState.STOPPING, SlotState.STOPPED, SlotState.CRASHED:
            debug "processLangserverQueue: slot is inactive", uri = q.uri, state = slotThatOwnsUri.state
            if not q.responseFuture.finished:
              q.responseFuture.cancel()
            continue

        else:
          # File is open but no slot owns it (e.g. the slot was evicted from the pool).
          debug "processLangserverQueue: file is open but no slot owns it", uri = q.uri
          if not q.responseFuture.finished:
            q.responseFuture.cancel()

      elif path in ls.pool.slots:
        let slot = ls.pool.slots[path]
        case slot.state
        of SlotState.READY, SlotState.SPAWNING:
          debug "processLangserverQueue: Add path-level query to mailbox. ", uri = q.uri, kind = $q.kind
          ls.pool.slots[path].queryMailbox.addLastNoWait(q)
        else:
          debug "processLangserverQueue: Could not add path-level message to mailbox. Slot is not live.", uri = q.uri, kind = $q.kind
          q.responseFuture.cancel()

      else:
        debug "processLangserverQueue: Could not add message to mailbox", uri = q.uri, kind = $q.kind
        q.responseFuture.cancel()

    of LangserverQueryKind.FILE_ACCESS:
      let q = query.fileAccess
      case q.kind
      of FileAccessQueryKind.DID_OPEN:
        await ls.processDidOpenQuery(q)
            
      of FileAccessQueryKind.DID_CHANGE:
        await ls.processDidChangeQuery(q)

      of FileAccessQueryKind.DID_SAVE:
        await ls.processDidSaveQuery(q)

      of FileAccessQueryKind.DID_CLOSE:
        await ls.processDidCloseQuery(q)

      of FileAccessQueryKind.DID_RENAME_FILES:
        await ls.processDidRenameQuery(q)
       
      of FileAccessQueryKind.DID_DELETE_FILES:
        await ls.processDidDeleteQuery(q)

      of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
        debug "Changed configuration: "
        let oldConfiguration = ls.configurations.currentConfig
        var newConfiguration: NlsConfig
        if ls.usePullConfigurationModel():
          if ls.supportsConfigurationRequest():
            debug "Requesting configuration from the client"
            let configurationParams = %*{"items": [{"section": "nimTortoise"}]}
            let configFuture = ls.call("workspace/configuration", configurationParams)
            let receivedConfigJson = await configFuture
            debug "workspace/configuration response", response = receivedConfigJson
            let parsedConfig = parseWorkspaceConfigurationResponse(receivedConfigJson)
            newConfiguration = parsedConfig.get(oldConfiguration)
          else:
            debug "Client does not support workspace/configuration"
            ls.configurations.configReady.fire()
            continue
        else:
          newConfiguration = parseDidChangeConfiguration(q.didChangeConfiguration)

        let newConfigurationIsDifferent = isDifferentFrom(newConfiguration, oldConfiguration)

        if newConfigurationIsDifferent:
          ls.configurations.currentConfig = newConfiguration

        debug "Current performance ", kind = $ls.configurations.currentConfig.performance.kind, throttling = $ls.configurations.currentConfig.performance.fileCheckThrottling, updateOnChange = $ls.configurations.currentConfig.performance.updateOnChange

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
      
      of FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL:
        let uri = q.willSave.textDocument.uri
        let config = ls.configurations.currentConfig
        let nphPath = getNphPath()

        let shouldFormat =
          nphPath.isSome() and ls.capabilities.lspServerCapabilities.documentFormattingProvider.get(false) and
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

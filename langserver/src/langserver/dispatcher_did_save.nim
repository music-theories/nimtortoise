import std/[options, sets, tables, strutils, json, times]
import chronos
import chronicles
import ../nimsuggest/nimsuggest
import ../nimble/nimble_utils
import ../protocol/types
import ../utils/utils
import ./[langserver_types, query_types]

proc processDidSaveQuery*(
  ls: LanguageServer, q: FileAccessQuery
) {.async.} = 
  let params: TextDocumentIdentifier = q.didSave.textDocument
  let uri = params.uri
  debug "didSave: file", uri = uri
  if uri notin ls.files.openFiles:
    debug "didSave: file is not in open files (should not be possible)", uri = uri
  else:
    let fileInfo = ls.files.openFiles[uri]

    ls.files.openFiles[uri].lastSaved = times.now()
    ls.files.openFiles[uri].lastUserInteraction = times.now()

    let slotCheck = getSlotThatOwnsUri(ls.pool, uri)
    if slotCheck.isNone():
      debug "processDidSaveQuery: Open file does not have a slot", uri = uri
      # TODO - I think this is a place in which you need to check whether this file is owned by a slot, and if not, add it, or create a new slot.  Saving is a clear indication that this file is being worked on.
      ls.langserverQueue.addFirstNoWait(LangserverQuery(
        kind: LangserverQueryKind.FILE_ACCESS,
        fileAccess: FileAccessQuery(
          kind: FileAccessQueryKind.DID_OPEN,
          didOpen: DidOpenTextDocumentParams(
            textDocument: fileInfo.textDocument
          )
        )
      ))

    else:
      let slotThatOwnsUri = slotCheck.get()
      if uri in slotThatOwnsUri.crashedUris:
        slotThatOwnsUri.crashedUris.excl(uri)

      if q.didSave.text.isSome():
        let stashLocation = uriToStashFilePath(ls.files.storageDir, uri)
        let file = open(string(stashLocation), fmWrite)
        fileInfo.fingerTable = @[]
        for line in q.didSave.text.get.splitLines:
          fileInfo.fingerTable.add(line.createUTFMapping())
          file.writeLine(line)
        file.close()

      # Directly query nimsuggest
      case slotThatOwnsUri.state
      of SlotState.READY, SlotState.SPAWNING:
        debug "didSave: sending CHANGED query", uri = uri

        let changedQuery = NimsuggestQuery[LspFilePosition](
          id: 0,
          kind: NimsuggestQueryKind.CHANGED,
          uri: uri,
          dirtyFile: uriToStashFilePath(ls.files.storageDir, uri),
          saved: true,
          isDependency: false,
          responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
        )
        slotThatOwnsUri.queryMailbox.addLastNoWait(changedQuery)
        
      of SlotState.STOPPING, SlotState.STOPPED, SlotState.CRASHED:
        discard

      # Clear this file's module entry point from crashedSlots.
      let savedFilePath = toFilePathAbs(uri)
      let savedSpawnInfo = getNimsuggestSpawnInfo(
        savedFilePath, ls.files.rootPath, ls.dependencies
      )

      debug "didSave: clearing crashedSlots for module entry point",
        entryPoint = savedSpawnInfo.entryPoint,
        savedFile = savedFilePath

      ls.pool.crashedSlots.excl(savedSpawnInfo.entryPoint)
      ls.pool.crashedSlots.excl(savedFilePath)

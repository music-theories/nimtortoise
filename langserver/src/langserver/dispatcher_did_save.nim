import std/[options, sets, tables, strutils, json]
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
  let uri = q.didSave.textDocument.uri
  debug "didSave: file", uri = uri
  if uri in ls.files.openFiles:
    let fileInfo = ls.files.openFiles[uri]
    let slotCheck = getSlotThatOwnsUri(ls.pool, uri)
    if slotCheck.isNone():
      debug "processDidSaveQuery: Open file does not have a slot", uri = uri

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

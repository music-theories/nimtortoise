import std/[tables, sequtils, times, strutils]
import chronos
import chronicles
import ../nimsuggest/nimsuggest
import ../protocol/types
import ../utils/utils
import ./[langserver_types, query_types]
import ./[langserver_utils]

proc saveFileChangesToStash(
  ls: LanguageServer,
  uri: FileUri,
  contentChanges: seq[TextDocumentContentChangeEvent]
): seq[seq[tuple[u16pos, offset: int]]] = 
  ## Returns fingerTable
  result = @[]
  let stashLocation = ls.uriStorageLocation(uri)
  let file = open(string(stashLocation), fmWrite)

  if contentChanges.len <= 0:
    file.close()
    return @[]
  else:
    for line in contentChanges[0].text.splitLines:
      # fingertable is 0-based.
      result.add(line.createUTFMapping())
      file.writeLine(line)
    file.close()

proc processDidChangeQuery*(
  ls: LanguageServer, q: FileAccessQuery
) {.async.} = 
  # let didChangeQuery: NimsuggestQuery
  let didChangeParams: DidChangeTextDocumentParams = q.didChange

  let uri = q.didChange.textDocument.uri
  let contentChanges: seq[TextDocumentContentChangeEvent] = didChangeParams.contentChanges
  let textDocument: VersionedTextDocumentIdentifier = didChangeParams.textDocument

  let languageId = ""
  let version = 0
  let savedContent: string = if contentChanges.len > 0: contentChanges[0].text else: ""

  let openFiles = ls.files.openFiles.keys.toSeq()

  if uri in ls.files.openFiles:
    debug "processDidChangeQuery: DID_CHANGE file is in openFiles. Saving stash. ", uri = uri, openFiles = openFiles

    ls.files.openFiles[uri].fingerTable = ls.saveFileChangesToStash(
      uri, contentChanges
    )
    ls.files.openFiles[uri].lastChanged = times.now()

    let slot = ls.files.openFiles[uri].slot

    case slot.state
    of SlotState.SPAWNING, SlotState.READY:
      debug "processDidChangeQuery: DID_CHANGE dispatcher adding CHANGED message to slot mailbox", uri = uri
      let changedQuery = NimsuggestQuery[LspFilePosition](
        id: 0,
        kind: NimsuggestQueryKind.CHANGED,
        uri: uri,
        dirtyFile: ls.uriStorageLocation(uri),
        responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
        saved: false
      )  
      slot.queryMailbox.addLastNoWait(changedQuery)

    of SlotState.STOPPED:
      debug "processDidChangeQuery: DID_CHANGE dispatcher could not add CHANGED message to dead slot mailbox.  Send synthetic DID_OPEN message to try and open slot", uri = uri
      let changedQuery = NimsuggestQuery[LspFilePosition](
        id: 0,
        kind: NimsuggestQueryKind.CHANGED,
        uri: uri,
        dirtyFile: ls.uriStorageLocation(uri),
        responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
        saved: false
      )  

      ls.langserverQueue.addFirstNoWait(LangserverQuery(
        kind: LangserverQueryKind.NIMSUGGEST,
        nimsuggest: changedQuery
      ))

      ls.langserverQueue.addFirstNoWait(LangserverQuery(
        kind: LangserverQueryKind.FILE_ACCESS,
        fileAccess: FileAccessQuery(
          kind: FileAccessQueryKind.DID_OPEN,
          didOpen: DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(
              uri: uri,
              languageId: languageID,
              version: version,
              text: savedContent
            ) 
          )
        )
      ))

    of SlotState.CRASHED, SlotState.STOPPING:
      debug "processDidChangeQuery: DID_CHANGE dispatcher cannot add message to slot in CRASHED or STOPPING mailbox", uri = uri, state = slot.state, entryPoint = slot.spawnInfo.entryPoint
      

  else:
    debug "processDidChangeQuery: DID_CHANGE file is NOT in openFiles.  Sending synthetic DID_OPEN message. ", uri = uri, openFiles = openFiles
    let changedQuery = NimsuggestQuery[LspFilePosition](
      id: 0,
      kind: NimsuggestQueryKind.CHANGED,
      uri: uri,
      dirtyFile: ls.uriStorageLocation(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
      saved: false
    )  

    ls.langserverQueue.addFirstNoWait(LangserverQuery(
      kind: LangserverQueryKind.NIMSUGGEST,
      nimsuggest: changedQuery
    ))

    ls.langserverQueue.addFirstNoWait(LangserverQuery(
      kind: LangserverQueryKind.FILE_ACCESS,
      fileAccess: FileAccessQuery(
        kind: FileAccessQueryKind.DID_OPEN,
        didOpen: DidOpenTextDocumentParams(textDocument: TextDocumentItem(
          uri: uri,
          languageId: languageID,
          version: version,
          text: savedContent
        ))
      )
    ))

import std/[json, sequtils, strformat, sets, options, strutils]
import chronos
import chronicles
import ../protocol/types
import ../langserver/langserver
import ../nimsuggest/nimsuggest
import ../utils/process_utils
import ../utils/utils
import ./[queries_nimsuggest, request_text_document]

# === workspace/symbol ===
proc processWorkspaceSymbolResponses*(
  ls: LanguageServer,
  nimsuggestResponses: seq[Suggest],
  params: WorkspaceSymbolParams, 
): seq[SymbolInformation] =
  let responses = processDocumentSymbolResponses(ls, nimsuggestResponses)
  let query = params.query.toLowerAscii()
  if query.len > 0:
    return responses.filterIt(query in it.name.toLowerAscii())
  else:
    return @[]
  
proc workspaceSymbol*(
  ls: LanguageServer, 
  params: WorkspaceSymbolParams, 
  id: int
): Future[seq[SymbolInformation]] {.async.} =
  # Route through any live slot's queryMailbox.
  var futures: seq[Future[seq[Suggest]]]
  for slot in ls.pool.slots.values:
    if slot.isLive():
      let q = ls.initNimsuggestFileQuery(
        id, toUri(slot.spawnInfo.entryPoint),
        NimsuggestQueryKind.WORKSPACE_SYMBOLS
      )
      futures.add(ls.addQueryToQueue(q))

  if futures.len == 0:
    return @[]
  await allFutures(futures)
  var merged: seq[Suggest]
  for f in futures:
    merged.add(f.read())

  return processWorkspaceSymbolResponses(
    ls, merged, params
  )
  
proc applyEdit*(
  ls: LanguageServer, params: ApplyWorkspaceEditParams
): Future[ApplyWorkspaceEditResponse] {.async.} =
  let res = await ls.call("workspace/applyEdit", %params)
  res.to(ApplyWorkspaceEditResponse)

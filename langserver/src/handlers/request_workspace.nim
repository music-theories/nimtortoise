import std/[json, sequtils, strformat, sets, options, strutils]
import chronos
import chronicles
import ../protocol/types
import ../langserver/langserver
import ../nimsuggest/nimsuggest
import ../utils/process_utils
import ../utils/utils
import ./[queries_nimsuggest, request_text_document]

# === workspace/executeCommand ===
proc resolveSlot(ls: LanguageServer, projectFile: FilePath): Option[NimsuggestSlot] =
  ## Find the slot responsible for `projectFile`.
  ## The extension sends the active editor file, which may not be a pool entry
  ## point; fall back to the open-files table to find the owning slot.
  if projectFile in ls.pool.slots:
    return some(ls.pool.slots[projectFile])
  let uri = pathToUri(projectFile)
  if uri in ls.files.openFiles:
    return some(ls.files.openFiles[uri].slot)
  return none(NimsuggestSlot)


##[
TODO: Execute command is going to be the main mechanism through which any extension code is run, and the `extensions/listTasks` type requests will just be wrappers around this.  `executeCommand` is the standard LSP way to expose the different functionalities.

These need to be added to the LspExtensionCapability object
  LspExtensionCapability* = enum
    #List of extensions this server support. Useful for clients
    excRestartSuggest = "RestartSuggest"
    excNimbleTask = "NimbleTask"
    excRunTests = "RunTests"

WORKING
- status
- capabilities
- suggest/restart
- listTasks
- runTask
TODO
- 

STUBBED
- macroExpand
- runTests
- cancelTest
]##

proc executeCommand*(
  ls: LanguageServer, params: ExecuteCommandParams
): Future[JsonNode] {.async.} =
  let projectFile = FilePath(params.arguments[0].getStr)
  case params.command
  of "nimtortoise.restart":
    debug "Restarting nimsuggest", projectFile = projectFile
    let slot = ls.resolveSlot(projectFile)
    if slot.isSome:
      let resolvedSlot = slot.get()
      resolvedSlot.crashedUris.clear()
      discard await execStop(resolvedSlot, ls.pool)
      traceAsyncErrors execSpawn(
        resolvedSlot, ls.pool, 
        resolvedSlot.projectFile, 
        ls.configurations.currentConfig
      )

  of "nimtortoise.checkProject":
    debug "Checking project", projectFile = projectFile
    let slot = ls.resolveSlot(projectFile)
    if slot.isSome:
      let resolvedSlot = slot.get()
      ls.langserverQueue.addLastNoWait(LangserverQuery(
        kind: LangserverQueryKind.NIMSUGGEST,
        nimsuggest: NimsuggestQuery[LspFilePosition](
          id: 0,
          kind: NimsuggestQueryKind.CHECK_PROJECT,
          uri: pathToUri(resolvedSlot.projectFile),
          dirtyFile: FilePath(""),
          responseFuture: newFuture[seq[Suggest]]("checkProject"),
        )
      ))

  of "nimtortoise.recompile":
    debug "Clean build", projectFile = projectFile
    let slot = ls.resolveSlot(projectFile)
    if slot.isSome:
      let resolvedSlot = slot.get()
      if resolvedSlot.isLive:
        let entryPoint = resolvedSlot.projectFile
        let token = fmt "Compiling {entryPoint}"
        ls.workDoneProgressCreate(token)
        ls.progress(token, "begin", fmt "Compiling project {entryPoint}")
        discard await execStop(resolvedSlot, ls.pool)
        discard await execSpawn(
          resolvedSlot, ls.pool, 
          entryPoint, 
          ls.configurations.currentConfig
        )
        ls.progress(token, "end")
        ls.langserverQueue.addLastNoWait(LangserverQuery(
          kind: LangserverQueryKind.NIMSUGGEST,
          nimsuggest: NimsuggestQuery[LspFilePosition](
            id: 0,
            kind: NimsuggestQueryKind.CHECK_PROJECT,
            uri: pathToUri(entryPoint),
            dirtyFile: FilePath(""),
            responseFuture: newFuture[seq[Suggest]]("recompile"),
          )
        ))

  result = newJNull()

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
        id, pathToUri(slot.projectFile), 
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

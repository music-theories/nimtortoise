import std/[options, os, strutils, strscans, strformat, json, tables, sequtils]
import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils
import forest

import ../protocol/[types]
import ../langserver/langserver
import ../nimsuggest/nimsuggest
# import ../nim_compiler/[testrunner, nim_compiler]
import ../nimble/[nimble]
# import ../utils/process_utils
import ../utils/utils


# === workspace/executeCommand ===
proc resolveSlot(ls: LanguageServer, projectFile: FilePathAbs): Option[NimsuggestSlot] =
  ## Find the slot responsible for `projectFile`.
  ## The extension sends the active editor file, which may not be a pool entry
  ## point; fall back to the open-files table to find the owning slot.
  if projectFile in ls.pool.slots:
    return some(ls.pool.slots[projectFile])
  let uri = toUri(projectFile)
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

# TODO
# type 
  # ExtensionCommand* = object
  #   case kind*: LspExtensionCapability
  #   of SERVER_RESTART: discard      
  #   of NIMSUGGEST_RESTART, NIMSUGGEST_CHECK_PROJECT, NIMSUGGEST_RECOMPILE: 
  #     slot*: FilePathAbs
  #   of NIMBLE_LIST_TASKS: discard
  #   of NIMBLE_RUN_TASK: discard
  #   of NIM_MACRO_EXPAND: discard

# proc processExtensionCommands*(
#   ls: LanguageServer, params: ExecuteCommandParams
# ): Future[JsonNode] {.async.} =

proc executeCommand*(
  ls: LanguageServer, params: ExecuteCommandParams
): Future[JsonNode] {.async.} =
  let projectFile = FilePathAbs(params.arguments[0].getStr)
  case params.command
  of "nimtortoise.restart":
    debug "Restarting nimsuggest", projectFile = projectFile
    if projectFile in ls.pool.slots:
      await restartSlot(
        ls.pool.slots[projectFile],
        ls.pool,
        ls.files.openFiles,
        ls.configurations.currentConfig,
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
          uri: toUri(resolvedSlot.spawnInfo.entryPoint),
          dirtyFile: FilePathAbs(""),
          responseFuture: newFuture[seq[Suggest]]("checkProject"),
        )
      ))

  of "nimtortoise.recompile":
    debug "Recompile Nimsuggest instance ", projectFile = projectFile
    let slot = ls.resolveSlot(projectFile)
    if slot.isSome:
      let resolvedSlot = slot.get()
      if resolvedSlot.isLive():
        let entryPoint = resolvedSlot.spawnInfo.entryPoint
        ls.langserverQueue.addLastNoWait(LangserverQuery(
          kind: LangserverQueryKind.NIMSUGGEST,
          nimsuggest: NimsuggestQuery[LspFilePosition](
            id: 0,
            kind: NimsuggestQueryKind.RECOMPILE,
            uri: toUri(entryPoint),
            dirtyFile: FilePathAbs(""),
            responseFuture: newFuture[seq[Suggest]]("recompile"),
          )
        ))

  result = newJNull()

# === extension/macroExpand ===
proc expand*(ls: LanguageServer, params: JsonNode): Future[JsonNode] {.async.} =
  # TODO: implement macro expansion via nimExpandMacro
  return newJNull()

# === extension/status ===
proc status*(ls: LanguageServer, params: NimLangServerStatusParams): Future[NimLangServerStatus] {.async.} =
  return ls.getLspStatus()

# === extension/capabilities ===
proc extensionCapabilities*(ls: LanguageServer, params: JsonNode): Future[seq[LspExtensionCapability]] {.async.} =
  return @[excRestartSuggest, excNimbleTask, excRunTests]

# === extension/suggest ===
proc extensionSuggest*(ls: LanguageServer, params: SuggestParams): Future[SuggestResult] {.async.} =
  debug "extensionSuggest called", action = $params.action, projectFile = params.projectFile
  case params.action
  of saRestart:
    let projectFilePath = FilePathAbs(params.projectFile)
    if ls.pool.slots.hasKey(projectFilePath):
      asyncSpawn restartSlot(
        ls.pool.slots[projectFilePath],
        ls.pool,
        ls.files.openFiles,
        ls.configurations.currentConfig,
      )
    else:
      debug "extensionSuggest: no slot found for project", projectFile = params.projectFile
  of saRestartAll:
    restartAllNimsuggestInstances(
      ls.pool, ls.files.openFiles, ls.configurations.currentConfig, 
    )
  of saNone:
    discard
  return SuggestResult(actionPerformed: params.action)


# === extension/listTasks ===
proc listTasks*(ls: LanguageServer, conf: JsonNode): Future[seq[NimbleTask]] {.async.} =  
  await ls.lsInitialized
  # TODO - temporarily removed to fix other things
  return @[]
  # return await getNimbleTasks(ls.dependencies.nimble)

# === extension/tasks ===
proc tasks*(ls: LanguageServer, conf: JsonNode): Future[seq[NimbleTask]] {.async.} =  
  await ls.lsInitialized
  # TODO - temporarily removed to fix other things
  return @[]
  # return await getNimbleTasks(ls.dependencies.nimble)


# === extension/runTask ===
proc runTask*(
  ls: LanguageServer, params: RunTaskParams
): Future[RunTaskResult] {.async.} =
  await ls.lsInitialized
  return await runNimbleTask(params)
  
# === extension/listTests === 
# proc listTests*(
#   ls: LanguageServer, params: ListTestsParams
# ): Future[ListTestsResult] {.async.} =
#   let config = ls.configurations.currentConfig
#   let nimPath = config.getNimPath()
#   if nimPath.isNone:
#     error "Nim path not found when listing tests"
#     return ListTestsResult(
#       projectInfo: TestProjectInfo(
#         entryPoint: params.entryPoint, suites: initTable[string, TestSuiteInfo]()
#       )
#     )
#   # let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
#   let testProjectInfo = await listTests(
#     FilePathAbs(params.entryPoint),
#     FilePathAbs(nimPath.get()),
#     ls.files.rootPath
#   )
#   result.projectInfo = testProjectInfo

# # === extension/runTest === 
# proc runTests*(
#   ls: LanguageServer, params: RunTestParams
# ): Future[RunTestProjectResult] {.async.} =
#   let config = ls.configurations.currentConfig
#   let nimPath = getNimPath(config)
#   if nimPath.isNone:
#     error "Nim path not found when running tests"
#     return RunTestProjectResult()
#   debug "TODO Add test runner"
#   return RunTestProjectResult()
#   # let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
#   # await runTests(
#   #   ls,
#   #   params.entryPoint,
#   #   nimPath.get(),
#   #   params.suiteName,
#   #   params.testNames,
#   #   workspaceRoot,
#   # )

# # === extension/cancelTest === 
# proc cancelTest*(
#   ls: LanguageServer, params: JsonNode
# ): Future[CancelTestResult] {.async.} =
#   debug "Cancelling test"
#   if ls.testRunProcess.isSome:
#     await shutdownChildProcess(ls.testRunProcess.get)
#     ls.testRunProcess = none(AsyncProcessRef)
#     return CancelTestResult(cancelled: true)
#   return CancelTestResult(cancelled: false)

# === extension/restartServer === 

# TODO

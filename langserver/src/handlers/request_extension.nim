import std/[options, os, strutils, strscans, json, tables, sequtils]
import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils
import ../protocol/[types]
import ../langserver/langserver
import ../nimsuggest/nimsuggest
import ../nim_compiler/[testrunner, nim_compiler]
import ../nimble/[nimble, nimble_utils]
import ../utils/process_utils
import ../utils/utils

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
    let projectFilePath = FilePath(params.projectFile)
    if ls.pool.slots.hasKey(projectFilePath):
      asyncSpawn restartSlot(
        ls.pool.slots[projectFilePath], 
        ls.pool, 
        ls.configurations.currentConfig,
        ls.files.openFiles
      )
    else:
      debug "extensionSuggest: no slot found for project", projectFile = params.projectFile
  of saRestartAll:
    restartAllNimsuggestInstances(
      ls.pool, ls.configurations.currentConfig, ls.files.openFiles
    )
  of saNone:
    discard
  return SuggestResult(actionPerformed: params.action)


# === extension/tasks ===
proc tasks*(ls: LanguageServer, conf: JsonNode): Future[seq[NimbleTask]] {.async.} =  
  await ls.lsInitialized
  return await getNimbleTasks(ls.nimbleDumpCache)

# === extension/runTask ===
proc runTask*(
  ls: LanguageServer, params: RunTaskParams
): Future[RunTaskResult] {.async.} =
  await ls.lsInitialized
  return await runNimbleTask(params)
  
# === extension/listTests === 
proc listTests*(
  ls: LanguageServer, params: ListTestsParams
): Future[ListTestsResult] {.async.} =
  let config = ls.configurations.currentConfig
  let nimPath = config.getNimPath()
  if nimPath.isNone:
    error "Nim path not found when listing tests"
    return ListTestsResult(
      projectInfo: TestProjectInfo(
        entryPoint: params.entryPoint, suites: initTable[string, TestSuiteInfo]()
      )
    )
  # let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
  let testProjectInfo = await listTests(
    toFilePath(params.entryPoint), 
    FilePath(nimPath.get()), 
    ls.files.rootPath
  )
  result.projectInfo = testProjectInfo

# === extension/runTest === 
proc runTests*(
  ls: LanguageServer, params: RunTestParams
): Future[RunTestProjectResult] {.async.} =
  let config = ls.configurations.currentConfig
  let nimPath = getNimPath(config)
  if nimPath.isNone:
    error "Nim path not found when running tests"
    return RunTestProjectResult()
  debug "TODO Add test runner"
  return RunTestProjectResult()
  # let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
  # await runTests(
  #   ls,
  #   params.entryPoint,
  #   nimPath.get(),
  #   params.suiteName,
  #   params.testNames,
  #   workspaceRoot,
  # )

# === extension/cancelTest === 
proc cancelTest*(
  ls: LanguageServer, params: JsonNode
): Future[CancelTestResult] {.async.} =
  debug "Cancelling test"
  if ls.testRunProcess.isSome:
    await shutdownChildProcess(ls.testRunProcess.get)
    ls.testRunProcess = none(AsyncProcessRef)
    return CancelTestResult(cancelled: true)
  return CancelTestResult(cancelled: false)

# === extension/restartServer === 

# TODO

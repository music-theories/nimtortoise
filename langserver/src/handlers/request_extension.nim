import std/[json, tables]
import chronos
import chronicles
import forest
import api

import ../protocol/[types]
import ../langserver/langserver
import ../nimsuggest/nimsuggest
import ../nimble/[nimble]
import ../utils/utils

# === workspace/executeCommand ===
proc processExtensionCommandRequest(
  ls: LanguageServer, 
  request: ExtensionCommandRequest
): Future[ExtensionCommandResponse] {.async.} = 
  case request.kind
  of SERVER_STATUS:
    return ExtensionCommandResponse(
      kind: SERVER_STATUS, 
      serverStatus: ls.getLspStatus()
    )
  of SERVER_CAPABILITIES:
    return ExtensionCommandResponse(
      kind: SERVER_CAPABILITIES,
      serverCapabilities: getAllServerCapabilities()
    )
  of SERVER_RESTART:
    return ExtensionCommandResponse(
      kind: SERVER_RESTART
    )

  of NIMSUGGEST_RESTART_ALL:
    debug "Restart all Nimsuggest Instances"
    restartAllNimsuggestInstances(
      ls.pool, 
      ls.files.openFiles, 
      ls.dependencies, 
      ls.files.storageDir,
      ls.configurations.currentConfig, 
    )

    return ExtensionCommandResponse(
      kind: NIMSUGGEST_RESTART_ALL
    )
  of NIMSUGGEST_RECOMPILE:
    let slotName = request.slot
    debug "Recompile Nimsuggest instance ", slot = slotName
    if slotName in ls.pool.slots:
      let slot = ls.pool.slots[slotName]
      if slot.isLive():
        let entryPoint = slot.spawnInfo.entryPoint
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
    return ExtensionCommandResponse(
      kind: NIMSUGGEST_RECOMPILE
    )
  of NIMSUGGEST_RESTART:
    let slotName = request.slot
    debug "Restarting nimsuggest", slot = slotName
    if slotName in ls.pool.slots:
      await restartSlot(
        ls.pool.slots[slotName],
        ls.pool,
        ls.files.openFiles,
        ls.dependencies,
        ls.files.storageDir,
        ls.configurations.currentConfig,
      )
    return ExtensionCommandResponse(
      kind: NIMSUGGEST_RESTART
    )
  of NIMSUGGEST_STOP:
    return ExtensionCommandResponse(
      kind: NIMSUGGEST_STOP
    )
  of NIMSUGGEST_CHECK_PROJECT:
    let slotName = request.slot
    debug "Recompile Nimsuggest instance ", slot = slotName
    if slotName in ls.pool.slots:
      let slot = ls.pool.slots[slotName]
      ls.langserverQueue.addLastNoWait(LangserverQuery(
        kind: LangserverQueryKind.NIMSUGGEST,
        nimsuggest: NimsuggestQuery[LspFilePosition](
          id: 0,
          kind: NimsuggestQueryKind.CHECK_PROJECT,
          uri: toUri(slot.spawnInfo.entryPoint),
          dirtyFile: FilePathAbs(""),
          responseFuture: newFuture[seq[Suggest]]("checkProject"),
        )
      ))
    return ExtensionCommandResponse(
      kind: NIMSUGGEST_CHECK_PROJECT
    )

  of NIMBLE_LIST_TASKS:
    await ls.lsInitialized
    let allTasks = await getNimbleTasks(ls.dependencies.nimble)
    return ExtensionCommandResponse(
      kind: NIMBLE_LIST_TASKS,
      nimbleListTasks: allTasks
    )
    
  of NIMBLE_RUN_TASK:
    await ls.lsInitialized
    let taskRun = await runNimbleTask(
      request.nimbleRunTask.command,
      request.nimbleRunTask.workingDir
    )
    return ExtensionCommandResponse(
      kind: NIMBLE_RUN_TASK,
      nimbleRunTask: taskRun
    )

  of NIM_MACRO_EXPAND:
    return ExtensionCommandResponse(
      kind: NIM_MACRO_EXPAND,
    )

proc executeCommand*(
  ls: LanguageServer, 
  params: ExecuteCommandRequestParams
): Future[JsonNode] {.async.} =
  let asExtensionCommand = toExtensionCommandRequest(params)
  await ls.lsInitialized
  let processedCommands = ls.processExtensionCommandRequest(asExtensionCommand)
  try:
    let asJson = %* processedCommands
    return asJson
  except:
    return newJNull()

# === extension/status ===
proc status*(
  ls: LanguageServer, params: NimLangServerStatusParams
): Future[NimLangServerStatus] {.async.} =
  let processedCommands = await ls.processExtensionCommandRequest(ExtensionCommandRequest(kind: SERVER_STATUS))
  return processedCommands.serverStatus

# === extension/capabilities ===
proc extensionCapabilities*(
  ls: LanguageServer, params: JsonNode
): Future[seq[LspExtensionCapability]] {.async.} =
  let processedCommands = await ls.processExtensionCommandRequest(ExtensionCommandRequest(kind: SERVER_CAPABILITIES))
  return processedCommands.serverCapabilities
  
# === extension/listTasks ===
proc listTasks*(ls: LanguageServer, conf: JsonNode): Future[seq[NimbleTask]] {.async.} =  
  let processedCommands = await ls.processExtensionCommandRequest(ExtensionCommandRequest(kind: NIMBLE_LIST_TASKS))
  return processedCommands.nimbleListTasks

# === extension/runTask ===
proc runTask*(
  ls: LanguageServer, params: NimbleRunTaskRequest
): Future[NimbleRunTaskResponse] {.async.} =
  let processedCommands = await ls.processExtensionCommandRequest(ExtensionCommandRequest(
    kind: NIMBLE_RUN_TASK,
    nimbleRunTask: params
  ))
  let response: NimbleRunTaskResponse =  processedCommands.nimbleRunTask
  return response
  
# === extension/macroExpand ===
proc expand*(ls: LanguageServer, params: JsonNode): Future[JsonNode] {.async.} =
  # TODO: implement macro expansion via nimExpandMacro
  return newJNull()

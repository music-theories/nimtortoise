import
  std/[
    jsconsole, strutils, sequtils, jsfetch, asyncjs, options, strformat,
    sets, tables, times
  ]


import api
import resources/resources

import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[
  jsNodeFs, jsPromise
]

import ./[
  vscode_state_types, vscode_state_utils,
]

proc parseExeStatus(obj: JsObject): NimTortoiseExeStatus =
  result.path = FilePathAbs($(obj.path.to(cstring)))
  result.version = $(obj.version.to(cstring))

proc parsePerformanceSettingJs(obj: JsObject): PerformanceSettingJs =
  if not obj.kind.isUndefined():
    let kindStr = $(obj.kind.to(cstring))
    for k in PerformanceSettingKind:
      if $k == kindStr:
        result.kind = k
        break
  if not obj.fileCheckThrottling.isUndefined():
    result.fileCheckThrottling = obj.fileCheckThrottling.to(cstring)
  if not obj.updateOnChange.isUndefined():
    result.updateOnChange = obj.updateOnChange.to(bool)
  # if not obj.description.isUndefined:
  #   result.description = $(obj.description.to(cstring))

proc parsePendingRequest(obj: JsObject): PendingRequestStatus =
  result.name = $(obj.name.to(cstring))
  result.entryPoint = FilePathAbs($(obj.entryPoint.to(cstring)))
  result.time = $(obj.time.to(cstring))
  result.state = $(obj.state.to(cstring))

proc parseProjectError(obj: JsObject): ProjectError =
  result.entryPoint = FilePathAbs($(obj.entryPoint.to(cstring)))
  result.errorMessage = $(obj.errorMessage.to(cstring))
  result.lastKnownCmd = $(obj.lastKnownCmd.to(cstring))

proc parseNimsuggestStatus(obj: JsObject): NimsuggestStatus =
  result.state = $(obj.state.to(cstring))
  result.entryPoint = FilePathAbs($(obj.entryPoint.to(cstring)))
  result.protocol = $(obj.protocol.to(cstring))
  result.version = $(obj.version.to(cstring))
  result.path = $(obj.path.to(cstring))
  result.port = obj.port.to(int)
  if not obj.openFiles.isUndefined:
    let n = obj.openFiles.length.to(int)
    for i in 0 ..< n:
      result.openFiles.add($(obj.openFiles[i].to(cstring)))

proc parseServerStatus*(params: JsObject): NimTortoiseServerStatus =
  if not params.exe.isUndefined:
    result.exe = parseExeStatus(params.exe)

  if not params.performance.isUndefined:
    result.performance = parsePerformanceSettingJs(params.performance)

  if not params.extensionCapabilities.isUndefined:
    let n = params.extensionCapabilities.length.to(int)
    for i in 0 ..< n:
      let capStr = $(params.extensionCapabilities[i].to(cstring))
      for cap in LspExtensionCapability:
        if $cap == capStr:
          result.extensionCapabilities.add(cap)
          break

  if not params.openFiles.isUndefined:
    let n = params.openFiles.length.to(int)
    for i in 0 ..< n:
      result.openFiles.add(FilePathAbs($(params.openFiles[i].to(cstring))))

  if not params.pendingRequests.isUndefined:
    let n = params.pendingRequests.length.to(int)
    for i in 0 ..< n:
      result.pendingRequests.add(parsePendingRequest(params.pendingRequests[i]))

  if not params.projectErrors.isUndefined:
    let n = params.projectErrors.length.to(int)
    for i in 0 ..< n:
      result.projectErrors.add(parseProjectError(params.projectErrors[i]))

  if not params.pool.isUndefined:
    let n = params.pool.length.to(int)
    for i in 0 ..< n:
      result.pool.add(parseNimsuggestStatus(params.pool[i]))

proc fetchLsp*[T, U](
  state: ExtensionState, name: string, params: U
): Future[T] {.async.} =
  console.log("[FetchLsp] ", name, params.toJs())
  let response = await state.client.sendRequest(name, params.toJs())
  let res = jsonStringify(response).jsonParse(T)
  console.log(res)
  return res

proc fetchLsp*[T](state: ExtensionState, name: string): Future[T] =
  return fetchLsp[T, JsObject](state, name, ().toJs())

# === SERVER ===
# --- STATUS ---
proc sendServerStatusRequest*(state: ExtensionState): Future[NimTortoiseServerStatus] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/status", ().toJs())
  let lspStatus = parseServerStatus(response)
  state.channel.appendLine(($lspStatus).cstring)
  return lspStatus

proc refreshServerStatus*(
  state: ExtensionState,
  lspStatus: NimTortoiseServerStatus
) =
  state.statusProvider.status = some(lspStatus)
  state.statusProvider.emitter.fire(nil)
  for cap in lspStatus.extensionCapabilities:
    try:
      state.lspExtensionCapabilities.incl(cap)
      discard vscode.commands.executeCommand(
        "setContext",
        cstring("nimTortoise:" & $(cap)),
        true.toJs()
      )
    except ValueError:
      let errorString = "Error parsing server extension capability " & $(cap)
      console.error(cstring(errorString))

  state.onExtensionReady()

proc showNimLangServerStatus*(state: ExtensionState) {.async.} =
  let lspStatus: NimTortoiseServerStatus = await sendServerStatusRequest(state)
  refreshServerStatus(state, lspStatus)

proc sendServerCapabilitiesRequest*(
  state: ExtensionState
): Future[seq[LspExtensionCapability]] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/capabilities", ().toJs())
  let lspStatus = jsonStringify(response).jsonParse(seq[LspExtensionCapability])
  state.channel.appendLine(($lspStatus).cstring)
  return lspStatus

proc sendServerRestartRequest*(state: ExtensionState): Future[void] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/restart", ().toJs())
  let lspStatus = jsonStringify(response).jsonParse(seq[LspExtensionCapability])
  state.channel.appendLine(($lspStatus).cstring)
  # return lspStatus
  
proc sendPerformanceRequest*(state: ExtensionState) {.async.} =
  let items = newArrayWith[VscodeQuickPickItem](
    VscodeQuickPickItem{label: "HIGHEST", description: "Update open dependencies on change. Low request throttling. Highest CPU usage."},
    VscodeQuickPickItem{label: "HIGH",    description: "Update open dependencies on change. Medium request throttling. High CPU usage."},
    VscodeQuickPickItem{label: "LOW",     description: "Only update dependencies on save. Medium request throttling. Low CPU usage."},
    VscodeQuickPickItem{label: "LOWEST",  description: "Only update dependencies on save. High request throttling. Lowest CPU usage."},
  )
  let selected = await vscode.window.showQuickPick(items)
  if selected.isNil or not selected.toJs().to(bool):
    return
  await vscode.workspace.getConfiguration("nimTortoise").update("performance", selected.label)
  state.statusProvider.emitter.fire(nil)


# === NIMSUGGEST ===
proc buildNimsuggestRequest*(
  kind: LspExtensionCapability,
  slot: string
): JsObject =
  let params = newJsObject()
  params.command = cstring($(kind))
  let args = newJsObject()
  args.slot = slot.toJs()
  params.arguments = args.toJs()
  return params

# var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
# if activeEditor.isNil():
#   return
# let projectFile = activeEditor.document.fileName

proc sendNimsuggestExtensionRequest*(
  state: ExtensionState, 
  command: LspExtensionCapability, 
  slot: string
) {.async.} =
  state.outputLine((&"Sending nimsuggest request {command} for {slot}").cstring)
  let params = buildNimsuggestRequest(command, slot)
  discard await state.client.sendRequest("workspace/executeCommand", params)

proc sendNimsuggestCheckProjectRequest*(
  state: ExtensionState, slot: string
) {.async.} =
  discard sendNimsuggestExtensionRequest(
    state, NIMSUGGEST_CHECK_PROJECT, slot
  )

proc sendNimsuggestRestartRequest*(
  state: ExtensionState, slot: string
) {.async.} =
  discard sendNimsuggestExtensionRequest(
    state, NIMSUGGEST_RESTART, slot
  )

proc sendNimsuggestRecompileRequest*(
  state: ExtensionState, slot: string
) {.async.} =
  discard sendNimsuggestExtensionRequest(
    state, NIMSUGGEST_RECOMPILE, slot
  )

proc sendNimsuggestStopRequest*(
  state: ExtensionState, slot: string
) {.async.} =
  discard sendNimsuggestExtensionRequest(
    state, NIMSUGGEST_STOP, slot
  )

# proc sendNimsuggestStopForSlot*(state: ExtensionState, entryPoint: cstring) {.async.} =
#   state.outputLine((&"Stopping nimsuggest for {entryPoint}").cstring)
#   let params = buildNimsuggestRequest(NIMSUGGEST_STOP, $entryPoint)
#   discard await state.client.sendRequest("workspace/executeCommand", params)

# === NIMBLE ===
# --- LIST TASKS ---
# extension/listTasks
proc sendNimbleListTasksRequest*(state: ExtensionState) {.async.} =
  try:
    let tasks = await vscode.window.withProgress(
      VscodeProgressOptions{
        location: VscodeProgressLocation.notification,
        cancellable: false,
        title: "Nim: fetching Nimble tasks...".cstring,
      },
      proc(): Future[seq[NimbleTask]] =
        fetchLsp[seq[NimbleTask]](state, "extension/listTasks")
    )
    state.nimbleTasks = tasks
    state.statusProvider.emitter.fire(nil)
  except:
    console.error("refreshNimbleTasks failed".cstring, getCurrentExceptionMsg().cstring)

# --- RUN TASK ---
# extension/runTask
proc sendNimbleRunTaskRequest*(state: ExtensionState, name: cstring, projectDir: cstring = "") {.async.} =
  let task = state.getTaskByName(name, projectDir)
  if task.isNone or task.get.isRunning:
    console.log("Task already running or not found")
    return
  console.log("Executing nimbleRunTask", name, projectDir)
  let taskParams = NimbleRunTaskRequest(
    command: @[name],
    workingDir: projectDir
  )

  vscode.window
  .withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.notification,
      cancellable: false,
      title: cstring(fmt"Nim: running task '{name}'..."),
    },
    proc(): Promise[NimbleRunTaskResponse] =
      state.markTaskAsRunning(name, projectDir, true)
      state.statusProvider.emitter.fire(nil)
      fetchLsp[NimbleRunTaskResponse, NimbleRunTaskRequest](state, "extension/runTask", taskParams),
  )
  .then(
    proc(taskResult: NimbleRunTaskResponse) =
      state.markTaskAsRunning(name, projectDir, false)
      state.statusProvider.emitter.fire(nil)
      state.outputLine(fmt"Task {name} finished".cstring)
      for line in taskResult.output:
        state.outputLine(line)

      let panel = vscode.window.createWebviewPanel(
        "nimTask",
        cstring(fmt"Nim Task: {name}"),
        VscodeViewColumn.one,
        VscodeWebviewPanelOptions()
      )

      panel.webview.html = cstring(&"""
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <style>
            body {{
              padding: 10px;
              font-family: var(--vscode-editor-font-family);
              font-size: var(--vscode-editor-font-size);
            }}
            pre {{
              background-color: var(--vscode-editor-background);
              padding: 10px;
              border-radius: 4px;
              overflow-x: auto;
            }}
          </style>
        </head>
        <body>
          <h2>Task: {name}</h2>
          <h3>Command:</h3>
          <pre>{taskResult.command.mapIt($it).join(" ")}</pre>
          <h3>Output:</h3>
          <pre>{taskResult.output.mapIt($it).join("\n")}</pre>
        </body>
        </html>
      """)

  )
  .catch(
    proc(reason: JsObject) =
      state.markTaskAsRunning(name, projectDir, false)
      state.statusProvider.emitter.fire(nil)
      console.error("nimvscode - onNimbleTask Failed", reason)
  )

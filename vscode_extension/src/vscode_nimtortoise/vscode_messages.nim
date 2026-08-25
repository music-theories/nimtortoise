import
  std/[
    jsconsole, strutils, jsfetch, asyncjs, sugar, sequtils, options, strformat, times,
    sets, tables
  ]

import api
import forest

import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[
  jsNodeFs, jsNodePath, jsNodeCp, jsNodeUtil, jsNodeOs, jsNodeNet, jsPromise
]

import ./[
  vscode_state_types, vscode_state_utils,
]

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
  let lspStatus = jsonStringify(response).jsonParse(NimTortoiseServerStatus)
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

proc sendNimsuggestExtensionRequest*(
  state: ExtensionState, command: LspExtensionCapability
) {.async.} =
  var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
  if activeEditor.isNil():
    return
  let projectFile = activeEditor.document.fileName
  state.outputLine((&"Checking project nimsuggest for {projectFile}").cstring)
  let params = buildNimsuggestRequest(command, $projectFile)
  discard await state.client.sendRequest("workspace/executeCommand", params)

proc sendNimsuggestCheckProjectRequest*(state: ExtensionState) {.async.} =
  discard sendNimsuggestExtensionRequest(state, NIMSUGGEST_CHECK_PROJECT)

proc sendNimsuggestRestartRequest*(state: ExtensionState) {.async.} =
  discard sendNimsuggestExtensionRequest(state, NIMSUGGEST_RESTART)

proc sendNimsuggestRecompileRequest*(state: ExtensionState) {.async.} =
  discard sendNimsuggestExtensionRequest(state, NIMSUGGEST_RECOMPILE)

proc sendNimsuggestStopRequest*(state: ExtensionState) {.async.} =
  discard sendNimsuggestExtensionRequest(state, NIMSUGGEST_STOP)

# === NIMBLE ===
# --- LIST TASKS ---
# extension/listTasks
proc sendNimbleListTasksRequest*(state: ExtensionState) =
  vscode.window.withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.notification,
      cancellable: false,
      title: "Nim: fetching Nimble tasks...".cstring,
    },
    proc(): Future[seq[NimbleTask]] =
      fetchLsp[seq[NimbleTask]](state, "extension/listTasks")
  ).then(
    proc(tasks: seq[NimbleTask]) =
      state.nimbleTasks = tasks
  ).catch(
    proc(reason: JsObject) =
      console.error("refreshNimbleTasks failed".cstring, reason)
  )

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
    workingDir: DirPathAbs($projectDir)
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
      fetchLsp[NimbleRunTaskResponse, NimbleRunTaskRequest](state, "extension/runTask", taskParams),
  )
  .then(
    proc(taskResult: NimbleRunTaskResponse) =
      state.markTaskAsRunning(name, projectDir, false)
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
          <pre>{taskResult.command.join(" ")}</pre>
          <h3>Output:</h3>
          <pre>{taskResult.output.join("\n")}</pre>
        </body>
        </html>
      """)

  )
  .catch(
    proc(reason: JsObject) =
      console.error("nimvscode - onNimbleTask Failed", reason)
  )

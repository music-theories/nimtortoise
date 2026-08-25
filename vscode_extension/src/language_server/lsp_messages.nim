import
  std/[
    jsconsole, strutils, jsfetch, asyncjs, sugar, sequtils, options, strformat, times,
    sets, tables
  ]


import api

import platform/[vscodeApi, languageClientApi]

import
  platform/js/
    [jsNodeFs, jsNodePath, jsNodeCp, jsNodeUtil, jsNodeOs, jsNodeNet, jsPromise]


proc buildExecuteCommandRequest*(
  kind: LspExtensionCapability,
  slot: string
): JsObject  = 
  let params = newJsObject()
  params.command = $(kind).cstring
  params.slot = slot.toJs()
  return params

# === SERVER STATUS ===
proc fetchLspStatus*(state: ExtensionState): Future[NimLangServerStatus] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/status", ().toJs())
  let lspStatus = jsonStringify(response).jsonParse(NimLangServerStatus)
  state.channel.appendLine(($lspStatus).cstring)
  return lspStatus

# === NIMSUGGEST ===
# --- RESTART ALL ---
proc onLspSuggest*(action, projectFileIn: cstring) {.async.} =
  #Handles extension/suggest calls 
  #(right now only from the restart button in the suggest instance from the nim panel)
  var projectFile = projectFileIn
  if projectFile == "current":
    var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
    if activeEditor.isNil():
      return
    projectFile = activeEditor.document.fileName

  case action
  of "restart", "restartAll":
    outputLine((&"Path to file {projectFile}").cstring)
    let suggestParams = JsObject()
    suggestParams.action = action
    suggestParams.projectFile = projectFile
    let response =
      await fetchLsp[JsObject, JsObject](ext, "extension/suggest", suggestParams)
    console.log(response)
  else:
    console.error("Action not supported")



# --- RESTART ---

# --- RECOMPILE ---

# --- CHECK PROJECT ---

proc onCheckProject*() {.async.} =
  var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
  if activeEditor.isNil():
    return
  let projectFile = activeEditor.document.fileName
  let params = newJsObject()
  params.command = "nimtortoise.checkProject".cstring
  params.arguments = projectFile.toJs()

  discard await vscode.window.withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.notification,
      cancellable: false,
      title: "Nim: checking project...".cstring,
    },
    proc(): Future[JsObject] =
      ext.client.sendRequest("workspace/executeCommand", params)
  )
# --- STOP ---

# === NIMBLE ===

# --- LIST TASKS ---
# extension/listTasks
proc requestListTasks*() = # used to be refreshNimbleTasks
  vscode.window.withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.notification,
      cancellable: false,
      title: "Nim: fetching Nimble tasks...".cstring,
    },
    proc(): Future[seq[NimbleTask]] =
      fetchLsp[seq[NimbleTask]](ext, "extension/listTasks")
  ).then(
    proc(tasks: seq[NimbleTask]) =
      ext.nimbleTasks = tasks
  ).catch(
    proc(reason: JsObject) =
      console.error("refreshNimbleTasks failed".cstring, reason)
  )

# --- RUN TASK ---
# extension/runTask
proc requestRunNimbleTask*(name: cstring, projectDir: cstring = "") {.async.} =
  let task = ext.getTaskByName(name, projectDir)
  if task.isNone or task.get.isRunning:
    console.log("Task already running or not found")
    return
  console.log("Executing onNimbleTask", name, projectDir)
  let taskParams = RunTaskParams(command: @[name], workingDir: projectDir)

  vscode.window
  .withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.notification,
      cancellable: false,
      title: cstring(fmt"Nim: running task '{name}'..."),
    },
    proc(): Promise[RunTaskResult] =
      ext.markTaskAsRunning(name, projectDir, true)
      fetchLsp[RunTaskResult, RunTaskParams](ext, "extension/runTask", taskParams),
  )
  .then(
    proc(taskResult: RunTaskResult) =
      ext.markTaskAsRunning(name, projectDir, false)
      outputLine(fmt"Task {name} finished".cstring)
      for line in taskResult.output:
        outputLine(line)
      
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


# === NIM ===

# --- MACRO EXPAND ---
proc onLspSuggest*(action, projectFileIn: cstring) {.async.} =
  #Handles extension/suggest calls 
  #(right now only from the restart button in the suggest instance from the nim panel)
  var projectFile = projectFileIn
  if projectFile == "current":
    var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
    if activeEditor.isNil():
      return
    projectFile = activeEditor.document.fileName

  case action
  of "restart", "restartAll":
    outputLine((&"Path to file {projectFile}").cstring)
    let suggestParams = JsObject()
    suggestParams.action = action
    suggestParams.projectFile = projectFile
    let response =
      await fetchLsp[JsObject, JsObject](ext, "extension/suggest", suggestParams)
    console.log(response)
  else:
    console.error("Action not supported")

proc onCheckProject*() {.async.} =
  var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
  if activeEditor.isNil():
    return
  let projectFile = activeEditor.document.fileName
  let params = newJsObject()
  params.command = "nimtortoise.checkProject".cstring
  params.arguments = @[projectFile.toJs()]
  discard await vscode.window.withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.notification,
      cancellable: false,
      title: "Nim: checking project...".cstring,
    },
    proc(): Future[JsObject] =
      ext.client.sendRequest("workspace/executeCommand", params)
  )





# proc fetchListTests*(state: ExtensionState, params: ListTestsParams): Future[ListTestsResult] {.async.} =
#   let client = state.client
#   let response = await client.sendRequest("extension/listTests", params.toJs())
#   console.log(response.jsonStringify())
#   let test = response.jsonStringify().jsonParse(ListTestsResult)
#   return test

# proc requestRunTest*(state: ExtensionState, params: RunTestParams): Future[RunTestProjectResult] {.async.} =
#   let client = state.client
#   let response = await client.sendRequest("extension/runTests", params.toJs())
#   console.log(response.jsonStringify())
#   let test = response.jsonStringify().jsonParse(RunTestProjectResult)
#   return test

# proc requestCancelTest*(state: ExtensionState): Future[CancelTestResult] {.async.} =
#   let client = state.client
#   let response = await client.sendRequest("extension/cancelTest", ().toJs())
#   console.log(response.jsonStringify())
#   let test = response.jsonStringify().jsonParse(CancelTestResult)
#   return test
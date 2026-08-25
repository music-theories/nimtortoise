## This is the extension file that gets loaded by vscode

when not defined(js):
  {.error: "This module only works on the JavaScript platform".}

import std/[strformat, jsconsole, sugar]

import ./platform/vscodeApi
import ./platform/js/[jsString, jsNodeFs]

import ./vscode_nimtortoise/[
  init_vscode_extension,
  vscode_state_types, vscode_state_utils,
  vscode_notifications, vscode_messages,
  vscode_panel, vscode_panel_utils
]
import ./text_display/[code_lenses, language_configuration]

var state: ExtensionState

proc activate*(ctx: VscodeExtensionContext): void {.async.} =
  var config = vscode.workspace.getConfiguration("nimTortoise")
  state = ExtensionState(
    ctx: ctx,
    config: config,
    channel: vscode.window.createOutputChannel("Nim"),
    lspChannel: vscode.window.createOutputChannel("Nim Lsp"),
  )

  # --- VS Code ---
  vscode.commands.registerCommand("nimTortoise.showNotification", onShowNotification)
  vscode.commands.registerCommand("nimTortoise.onDeleteNotification", proc (args: JsObject) = onDeleteNotification(state, args))
  vscode.commands.registerCommand(
    "nimTortoise.onClearAllNotifications", () => onClearAllNotifications(state)
  )

  # --- Extension ---
  vscode.commands.registerCommand(
    "nimTortoise.showNimLangServerStatus", () => sendServerStatusRequest(state)
  )
  vscode.commands.registerCommand("nimTortoise.setPerformance", proc () {.async.} = await sendPerformanceRequest(state))
  vscode.commands.registerCommand(
    "nimTortoise.nimbleListTasks", proc() = sendNimbleListTasksRequest(state)
  )
  vscode.commands.registerCommand(
    "nimTortoise.nimbleRunTask",
    proc(args: JsObject) =
      let name = args[0].to(cstring)
      let dir = args[1].to(cstring)
      discard sendNimbleRunTaskRequest(state, name, dir)
  )
  # --- Nimsuggest
  vscode.commands.registerCommand("nimTortoise.nimsuggestRestart",
    proc() {.async.} = await sendNimsuggestRestartRequest(state)
  )
  vscode.commands.registerCommand("nimTortoise.nimsuggestCheckProject",
    proc() {.async.} = await sendNimsuggestCheckProjectRequest(state)
  )
  vscode.commands.registerCommand("nimTortoise.nimsuggestRecompile",
    proc() {.async.} = await sendNimsuggestRecompileRequest(state)
  )
  vscode.commands.registerCommand("nimTortoise.nimsuggestStop",
    proc() {.async.} = await sendNimsuggestStopRequest(state)
  )

  # --- Pre-rewrite commands TODO ---
  # vscode.commands.registerCommand("nimTortoise.run.file", runFile)
  # vscode.commands.registerCommand("nimTortoise.debug.file", debugFile)
  # vscode.commands.registerCommand("nimTortoise.openGeneratedFile", openGeneratedFile)
  
  # vscode.commands.registerCommand(
  #   "nimTortoise.execSelectionInTerminal", execSelectionInTerminal
  # )

  # processConfig(config) # Not needed - this gets the project mapping
  # discard vscode.workspace.onDidChangeConfiguration(configUpdate)
  
  # vscode.debug.onDidStartDebugSession(onStartDebugSession)

  # setNimDir(state)
  await startVSCodeExtension(state)
  state.statusProvider = initNimLangServerStatusProvider(state)
  discard vscode.window.registerTreeDataProvider("nim", state.statusProvider)

  var languageConfig = initNimLanguageConfiguration()
  try:
    vscode.languages.setLanguageConfiguration(
      "nim", languageConfig
    )
  except:
    console.error(
      "language configuration failed to set",
      getCurrentException(),
      getCurrentExceptionMsg().cstring,
    )

  vscode.window.onDidChangeActiveTextEditor(showHideStatus, nil, state.ctx.subscriptions)

  initTerminalHandlers()

  console.log(
    fmt"""
        ExtensionContext:
        extensionPath:{ctx.extensionPath}
        storagePath:{ctx.storagePath}
        logPath:{ctx.logPath}
      """.cstring.strip()
  )
  # activateEvalConsole() TODO. - arbitrary code snippets
  if not fs.existsSync(ctx.storagePath):
    fs.mkdirSync(ctx.storagePath)

  outputLine(state, "[info] Extension Activated")
  # showNimbleSetupDialog()

  let nimbleCodeLensProvider = newCodeLensProvider(
    proc (
      document: VscodeTextDocument, 
      token: VscodeCancellationToken
    ): seq[VscodeCodeLens] = provideNimbleTasksCodeLenses(state.nimbleTasks, document, token)
  )
  ctx.subscriptions.add(
    vscode.languages.registerCodeLensProvider(
      VscodeDocumentFilter(language: "nimble", scheme: "file"),
      nimbleCodeLensProvider
    )
  )

  # Watch for .nimble files
  let nimbleWatcher = vscode.workspace.createFileSystemWatcher("**/*.nimble")
  nimbleWatcher.onDidChange(proc(uri: VscodeUri) =
    if uri.path == vscode.window.activeTextEditor.document.uri.path:
      discard 
  )
  ctx.subscriptions.add(nimbleWatcher)

proc deactivate*(): void {.async.} =
  await stopVSCodeExtension(state)

var module {.importc.}: JsObject
module.exports.activate = activate
module.exports.deactivate = deactivate

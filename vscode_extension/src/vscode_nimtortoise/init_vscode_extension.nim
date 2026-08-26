import std/[jsconsole, strutils, asyncjs, sugar, sequtils, strformat, times, options]
import api
import resources/resources

import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[jsNodeCp, jsNodeNet, jsPromise]

import ./[
  vscode_state_types, vscode_state_utils,
  vscode_notifications, vscode_messages,
  vscode_paths
]

proc startClientSocket(portFut: Future[int]): proc(): Future[ServerOptions] {.async.} =
  return proc(): auto {.async.} =
    let port = await portFut
    let socket = net.createConnection(
      port.cint,
      "localhost",
      proc(): void =
        discard,
    )
    var streamInfo = newJsObject()
    streamInfo.reader = socket
    streamInfo.writer = socket
    let serverOptions = cast[ServerOptions](streamInfo)
    return promiseResolve(serverOptions)

proc startSocket(
    nimlangserver: cstring, state: ExtensionState
): proc(): Future[ServerOptions] =
  let config = vscode.workspace.getConfiguration("nimTortoise")
  let port = config.getInt("lspPort").int
  if port != 0:
    #the user specified a port so we dont need to start the server process. It's assumed is already running
    return startClientSocket(promiseResolve(port))
  let process = cp.exec((nimlangserver & " --socket"), ExecOptions(env: getAugmentedEnv()), nil)
  let portPromise = newPromise(
    proc(resolve: proc(port: int), reject: proc(reasons: JsObject)) =
      process.stdout.onData(
        proc(data: Buffer) =
          let msg = $data.toString()
          if msg.startsWith("port="):
            try:
              let port = parseInt(msg.subStr(5).strip)
              console.log ("nimlangserver socket listening at " & $port).cstring
              resolve(port)
            except ValueError as ex:
              console.error (
                "An error ocurred trying to parse the port " & msg.substr(5) & ex.msg
              ).cstring
          state.lspChannel.appendLine msg.cstring
      )
      #StdError is directed to the output of the lsp which is the same as the stdio version does
      process.stderr.onData(
        (data: Buffer) => state.lspChannel.appendLine(data.toString())
      )
  )
  startClientSocket(portPromise)

# === LSP ===
proc startVSCodeExtension*(state: ExtensionState) {.async.} =
  let lspShellPath: Option[cstring] = getLspShellCommand()
  if lspShellPath.isNone():
    vscode.window.showInformationMessage(
      cstring("Unable to find nimTortoise binary - please add it to the settings: `nimTortoise.lsp.path`")
    )
  else:
    let langserverShellCommand: cstring = lspShellPath.get()

    outputLine(state, fmt"nimlangserver found: {langserverShellCommand}".cstring)
    outputLine(state, "Starting nimlangserver.")

    let serverOptions = ServerOptions{
      run: Executable{
        command: langserverShellCommand,
        transport: TransportKind.stdio,
        options: ExecutableOptions(shell: true, env: getAugmentedEnv()),
      },
      debug: Executable{
        command: langserverShellCommand,
        transport: TransportKind.stdio,
        options: ExecutableOptions(shell: true, env: getAugmentedEnv()),
      },
    }
    let clientOptions = LanguageClientOptions{
      documentSelector:
        @[
          DocumentFilter(scheme: cstring("file"), language: cstring("nim")),
          DocumentFilter(scheme: cstring("file"), language: cstring("nimble")),
          DocumentFilter(scheme: cstring("file"), language: cstring("nims")),
        ],
      outputChannel: state.lspChannel,
      # middleware: VscodeLanguageClientMiddleware(provideInlayHints: provideInlayHints),
      synchronize: WorkspaceSynchronizeOptions(configurationSection: cstring("nimTortoise")),
    }
    let config = vscode.workspace.getConfiguration("nimTortoise")
    let transportMode = config.getStr("transportMode")
    case transportMode
    of "socket":
      state.client = vscodeLanguageClient.newLanguageClient(
        cstring("nimTortoise"),
        cstring("Nim Tortoise Language Server"),
        startSocket(langserverShellCommand, state),
        clientOptions,
      )
    else:
      state.client = vscodeLanguageClient.newLanguageClient(
        cstring("nimTortoise"),
        cstring("Nim Tortoise Language Server"),
        serverOptions,
        clientOptions,
      )

    await state.client.start()

    state.client.onNotification(
      "extension/statusUpdate",
      proc(params: JsObject) =
        if params.projectErrors.isUndefined:
          params.projectErrors = newSeq[ProjectError]()
        if params.pendingRequests.isUndefined:
          params.pendingRequests = newSeq[PendingRequestStatus]()
        if params.extensionCapabilities.isUndefined:
          params.extensionCapabilities = newSeq[cstring]()

        let parseStatus = parseServerStatus(params)
        refreshServerStatus(state, parseStatus)
    )

    state.client.onNotification(
      "window/showMessage",
      proc(params: JsObject) =
        let message = jsonStringify(params).jsonParse(Message)
        inc state.statusProvider.lastId
        let id = $state.statusProvider.lastId
        let notification = Notification(
          message: message.message,
          detail: message.detail,
          kind: messageTypToStr(message.`type`),
          id: id.cstring,
          date: now(),
        )
        let nots = state.statusProvider.notifications & @[notification]
        refreshNotifications(state.statusProvider, nots),
    )

    let expiredTime = state.config.getInt("notificationTimeout")
    if expiredTime > 0:
      global.setInterval(
        proc() =
          let notifications = state.statusProvider.notifications.filterIt(
            it.date > now() - expiredTime.seconds
          )
          refreshNotifications(state.statusProvider, notifications),
        1000, #refresh time
      )

    outputLine(state, "Nim Tortoise Language Server started")

proc stopVSCodeExtension*(state: ExtensionState) {.async.} =
  await state.client.stop()

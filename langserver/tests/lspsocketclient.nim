## LSP socket client for tests — identical to tests/lspsocketclient.nim but
## updated import paths for the new src/ module hierarchy.

import std/[options, unittest, json, os, jsonutils, tables, strutils, sequtils, sugar]
import json_rpc/[rpcclient]
import chronicles

import ../src/configurations/configurations
import ../src/langserver/langserver
import ../src/nimsuggest/nimsuggest
import ../src/protocol/[types]
import ../src/utils/utils
import ../src/nimtortoise

# fixture paths are still under tests/ (shared with original test suite)
# proc fixtureUri*(path: string): FileUri =
#   result = toUri(FilePathAbs(getCurrentDir() / "tests" / path))

# fixtureUri that resolves from repo root, NOT tests/ (overrides lspsocketclient version)
proc fixtureUri*(path: string): FileUri =
  toUri(FilePathAbs(getCurrentDir() / path))

type
  NotificationRpc* = proc(params: JsonNode): Future[void] {.async.}
  Rpc* = proc(params: JsonNode): Future[JsonNode] {.async.}
  LspSocketClient* = ref object of RpcSocketClient
    notifications*: TableRef[string, NotificationRpc]
    routes*: TableRef[string, Rpc]
    calls*: TableRef[string, seq[JsonNode]]
    responses*: TableRef[int, Future[JsonNode]]

proc newLspSocketClient*(): LspSocketClient =
  result = LspSocketClient.new()
  result.routes = newTable[string, Rpc]()
  result.notifications = newTable[string, NotificationRpc]()
  result.calls = newTable[string, seq[JsonNode]]()
  result.responses = newTable[int, Future[JsonNode]]()
  # Respond to workspace/configuration so configReady fires after initialize.
  result.routes["workspace/configuration"] = proc(params: JsonNode): Future[JsonNode] {.async.} =
    return newJArray()

method call*(
    client: LspSocketClient, name: string, params: JsonNode
): Future[JsonNode] {.async.} =
  let id = client.getNextId()
  let reqJson = newJObject()
  reqJson["jsonrpc"] = %"2.0"
  reqJson["id"] = %id.num
  reqJson["method"] = %name
  reqJson["params"] = params
  let reqContent = wrapContentWithContentLength($reqJson)
  var jsonBytes = reqContent
  if client.transport.isNil:
    raise newException(
      JsonRpcError, "Transport is not initialised (missing a call to connect?)"
    )
  var newFut = newFuture[JsonNode]()
  client.responses[id.num] = newFut
  let res = await client.transport.write(jsonBytes)
  return await newFut

proc runRpc(client: LspSocketClient, rpc: Rpc, serverReq: JsonNode) {.async.} =
  let res = await rpc(serverReq["params"])
  let id = serverReq["id"].jsonTo(string)
  let reqJson = newJObject()
  reqJson["jsonrpc"] = %"2.0"
  reqJson["id"] = %id
  reqJson["result"] = res
  let reqContent = wrapContentWithContentLength($reqJson)
  discard await client.transport.write(reqContent.string)

proc processMessage(client: LspSocketClient, msg: string) {.raises: [].} =
  try:
    let serverReq = msg.parseJson()
    if "method" in serverReq:
      let meth = serverReq["method"].jsonTo(string)
      debug "[Process Data Loop ]", meth = meth
      if "id" in serverReq:
        if meth in client.routes:
          asyncSpawn runRpc(client, client.routes[meth], serverReq)
        else:
          error "Route not implemented ", meth = meth
      else:
        if meth in client.notifications:
          asyncSpawn client.notifications[meth](serverReq["params"])
        else:
          error "Method not implemented ", meth = meth
    elif "id" in serverReq:
      let id = serverReq["id"].jsonTo(int)
      let resultNode = if "result" in serverReq: serverReq["result"] else: newJNull()
      client.responses[id].complete(resultNode)
    else:
      warn "Unknown msg", msg = msg
  except CatchableError as exc:
    error "ProcessData Error ", msg = exc.msg

proc processData(client: LspSocketClient) {.async: (raises: []).} =
  while true:
    var localException: ref JsonRpcError
    while true:
      try:
        var value = await processContentLength(client.transport)
        if value == "":
          await client.transport.closeWait()
          break
        client.processMessage(value)
      except TransportError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break
      except CancelledError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break

    if localException.isNil.not:
      for _, fut in client.awaiting:
        fut.fail(localException)
      if client.batchFut.isNil.not and not client.batchFut.completed():
        client.batchFut.fail(localException)

    try:
      info "Reconnect to server", address = `$`(client.address)
      client.transport = await connect(client.address)
    except TransportError as exc:
      error "Error when reconnecting to server", msg = exc.msg
      break
    except CancelledError as exc:
      error "Error when reconnecting to server", msg = exc.msg
      break

proc connect*(client: LspSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  client.loop = processData(client)

proc notify*(client: LspSocketClient, name: string, params: JsonNode) =
  ## Send an LSP notification (no id, no response expected).
  ## Writes directly to the transport so the bytes are in the TCP buffer
  ## before this proc returns — callers can safely await a subsequent
  ## request and know the notification was sent first.
  let reqJson = newJObject()
  reqJson["jsonrpc"] = %"2.0"
  reqJson["method"] = %name
  reqJson["params"] = params
  let reqContent = wrapContentWithContentLength($reqJson)
  proc doWrite(): Future[void] {.async.} =
    discard await client.transport.write(reqContent)
  waitFor doWrite()

proc register*(client: LspSocketClient, name: string, notRpc: NotificationRpc) =
  client.notifications[name] = notRpc
  client.calls[name] = newSeq[JsonNode]()

proc register*(client: LspSocketClient, name: string, rpc: Rpc) =
  client.routes[name] = rpc

proc initialize*(
    client: LspSocketClient, initParams: LspInitializeParams
): Future[LspInitializeResult] {.async.} =
  client.call("initialize", %initParams).await.jsonTo(
    LspInitializeResult, Joptions(allowMissingKeys: true)
  )

proc positionParams*(uri: FileUri, line, character: int): TextDocumentPositionParams =
  return
    TextDocumentPositionParams %*
    {"position": {"line": line, "character": character}, "textDocument": {"uri": uri}}

proc notificationHandle*(
    args: (LspSocketClient, string), params: JsonNode
): Future[void] =
  try:
    let client = args[0]
    let name = args[1]
    if name in ["textDocument/publishDiagnostics", "$/progress"]:
      debug "[NotificationHandled ] Called for ", name = name
    else:
      debug "[NotificationHandled ] Called for ", name = name, params = params
    client.calls[name].add params
  except CatchableError:
    discard
  result = newFuture[void]("notificationHandle")

proc setWorkspaceConfig*(client: LspSocketClient, configJson: JsonNode) =
  ## Override the workspace/configuration response sent to the server.
  ## Call BEFORE notify("initialized") so the server reads the right config.
  ## configJson must be a JArray: [{"maxNimsuggestProcesses": 1, ...}]
  client.routes["workspace/configuration"] = proc(params: JsonNode): Future[JsonNode] {.async.} =
    return configJson

proc registerNotification*(client: LspSocketClient, names: varargs[string]) =
  for name in names:
    client.register(name, partial(notificationHandle, (client, name)))

proc waitForNotification*(
    client: LspSocketClient,
    name: string,
    predicate: proc(json: JsonNode): bool {.gcsafe, raises: [CatchableError].},
    timeoutMs: int = 10000,
): Future[bool] {.async.} =
  ## Poll `client.calls[name]` every 100ms until predicate matches or timeoutMs elapses.
  ## Uses a while loop instead of tail recursion to avoid accumulating Future objects.
  let timeout = if timeoutMs == 0: 10000 else: timeoutMs
  var elapsed = 0
  while elapsed <= timeout:
    try:
      for call in client.calls[name]:
        if predicate(call):
          debug "[WaitForNotification Predicate Matches] ", name = name, call = call
          return true
    except CatchableError as ex:
      error "[WaitForNotification]", ex = ex.msg
    await sleepAsync(100)
    elapsed += 100
  error "Couldn't match predicate ", calls = client.calls[name]
  return false

proc waitForNotificationMessage*(
    client: LspSocketClient, msg: string, timeoutMs: int = 10000
): Future[bool] {.async.} =
  ## Waits for a matching `window/logMessage` notification from the server.
  ## The server sends all status/init messages via window/logMessage (not showMessage).
  return await waitForNotification(
    client, "window/logMessage", (json: JsonNode) => json["message"].to(string) == msg,
    timeoutMs,
  )

proc stopServer*(client: LspSocketClient) =
  ## Cleanly shut down the language server via the LSP wire protocol.
  ## `shutdown` stops all nimsuggest processes; `exit` closes the transport.
  ## The sleepAsync gives Chronos one scheduler pass to flush the exit handler and
  ## close all sockets + pipe FDs, preventing both FD accumulation and port reuse
  ## across successive test suites.
  discard waitFor client.call("shutdown", newJNull())
  client.notify("exit", newJNull())
  waitFor sleepAsync(200)

proc startServer*(): (CommandLineParams, LanguageServer, LspSocketClient) =
  let cmdParams = CommandLineParams(
    # mode: some lsp,
    transport: some socket,
    port: getNextFreePort()
  )
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/logMessage", "window/workDoneProgress/create",
    "workspace/configuration", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  return (cmdParams, ls, client)


# Override createDidOpenParams to read from repo root
proc createDidOpenParams*(file: FilePathAbs): DidOpenTextDocumentParams =
  DidOpenTextDocumentParams %* {
    "textDocument": {
      "uri": toUri(file),
      "languageId": "nim",
      "version": 0,
      "text": readFile(string(file)),
    }
  }

proc generateSimpleNimblePaths*() =
  let dir = absolutePath("tests" / "projects" / "simple")
  writeFile(dir / "nimble.paths", "--noNimblePath\n")

proc generateMonorepoNimblePaths*() =
  let dir = absolutePath("tests" / "projects" / "monorepo")
  let pkgbSrc = dir / "pkgb" / "src"
  writeFile(
    dir / "nimble.paths",
    "--noNimblePath\n--path:\"" & pkgbSrc & "\"\n"
  )

proc doInitialize*(client: LspSocketClient, rootRelPath: string) =
  let initParams = LspInitializeParams %* {
    "processId": %getCurrentProcessId(),
    "rootUri": fixtureUri(rootRelPath),
    "capabilities": {
      "window": {"workDoneProgress": true},
      "workspace": {"configuration": true}
    }
  }
  discard waitFor client.initialize(initParams)

proc waitForNsInit*(client: LspSocketClient, absProjectFile: string): bool =
  result = waitFor client.waitForNotificationMessage(
    "Nimsuggest initialized for " & absProjectFile,
    timeoutMs = 50000,
  )

proc waitForInstanceCount*(client: LspSocketClient, n: int, timeoutMs = 30000): bool =
  waitFor client.waitForNotification(
    "extension/statusUpdate",
    proc(j: JsonNode): bool =
      let ports = j["pool"].elems.mapIt(it["port"].getInt).filterIt(it != 0)
      ports.deduplicate.len == n,
    0
  )

# proc sendDidOpen*(client: LspSocketClient, relPath: string) =
#   client.notify("textDocument/didOpen", %createDidOpenParams(relPath))

proc sendHover*(client: LspSocketClient, relPath: string, line, col: int): JsonNode =
  let uri = fixtureUri(relPath)
  waitFor client.call("textDocument/hover", %positionParams(uri, line, col))

proc sendCompletion*(client: LspSocketClient, relPath: string, line, col: int): JsonNode =
  let uri = fixtureUri(relPath)
  let params = CompletionParams %* {
    "position": {"line": line, "character": col},
    "textDocument": {"uri": uri}
  }
  waitFor client.call("textDocument/completion", %params)

proc sendDidChange*(client: LspSocketClient, relPath: string, version: int, newText: string) =
  let uri = fixtureUri(relPath)
  client.notify("textDocument/didChange", %* {
    "textDocument": {"uri": uri, "version": version},
    "contentChanges": [{"text": newText}]
  })

proc sendDidSave*(client: LspSocketClient, relPath: string, text: string) =
  let uri = fixtureUri(relPath)
  client.notify("textDocument/didSave", %* {
    "textDocument": {"uri": uri},
    "text": text
  })

proc sendDidRename*(client: LspSocketClient, oldRelPath, newRelPath: string) =
  let oldUri = fixtureUri(oldRelPath)
  let newUri = fixtureUri(newRelPath)
  client.notify("workspace/didRenameFiles", %* {
    "files": [{"oldUri": oldUri, "newUri": newUri}]
  })

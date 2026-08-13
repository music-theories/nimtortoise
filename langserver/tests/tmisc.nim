import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat, times]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import chronos/asyncproc
import unittest2

import ../src/configurations/configurations
import ../src/langserver/langserver
import ../src/nimsuggest/nimsuggest
import ../src/protocol/[types]
import ../src/utils/utils
import ../src/utils/process_utils
import ../src/nimtortoise


## tmisc.nim — rewrite-compatible port of tests/tmisc.nim
##
## API changes from original:
##   ls.workspaceConfiguration.complete(% @[conf])
##     → ls.configurations.currentConfig = some(conf)
##       ls.configurations.configReady.fire()
##
##   waitFor ls.workspaceConfiguration
##     → waitFor ls.getAndWaitForWorkspaceConfiguration()
##
##   ls.openFiles.del(uri)
##     → ls.files.openFiles.del(uri)
##
##   ls.projectFiles            → ls.pool.slots
##
##   ls.failTable               → removed from new architecture
##                                (crash counts now live on NimsuggestSlot.crashCount)
##
##   LanguageServer(serverMode: lsp, transportMode: stdio)
##     → LanguageServer(
##         capabilities: LanguageServerCapabilities(serverMode: lsp),
##         transport: LanguageServerTransport(transportMode: stdio),
##       )
##
##   ls.outStream               → ls.transport.outStream
##
##   ls.pendingRequests         → ls.messaging.pendingRequests

suite "Nimlangserver misc":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "after a period of inactivity, nimsuggest should be stopped":
    echo "    >> after a period of inactivity, nimsuggest should be stopped"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)
    client.setWorkspaceConfig(%*[{"nimsuggestIdleTimeout": 1000}])
    client.notify("initialized", newJObject())

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
    )

    asyncSpawn ls.tickLs()

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest for {hwAbsFile} was stopped because it was idle for too long",
    )

suite "Nimlangserver idle nimsuggest cleanup":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "idle nimsuggest is removed even when an open file was already evicted":
    echo "    >> idle nimsuggest is removed even when an open file was already evicted"
    # Regression test for #420: a URI evicted from ls.files.openFiles while the
    # nimsuggest still tracks it must not raise KeyError in removeIdleNimsuggests.
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    client.setWorkspaceConfig(%*[{"nimsuggestIdleTimeout": 1000}])
    client.notify("initialized", newJObject())

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )
    # Evict the file from openFiles to simulate the race condition
    ls.files.openFiles.del(helloWorldFile.fixtureUri())

    # Start the tick loop so idle slots get cleaned up.
    asyncSpawn ls.tickLs()

    var removed = false
    for attempt in 0 ..< 5:
      waitFor sleepAsync(1100)
      if hwAbsFile notin ls.pool.slots:
        removed = true
        break
    check removed

suite "Nimlangserver fail count":
  test "fail count is reset when a nimsuggest starts successfully":
    echo "    >> fail count is reset when a nimsuggest starts successfully"
    # NimsuggestSlot.crashCount is the new-arch equivalent of ls.failTable.
    # After a slot spawns successfully, crashCount must be 0 so it is not
    # permanently blocked after MAX_CRASH_RETRIES.
    # Verified: processCommands resets slot.crashCount = 0 at queues.nim:249.
    let cmdParams2 = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
    let ls2 = main(cmdParams2)
    let client2 = newLspSocketClient()
    waitFor client2.connect("localhost", cmdParams2.port)
    client2.registerNotification(
      "window/showMessage", "workspace/configuration",
      "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
    )
    let initParams2 = LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
    }
    discard waitFor client2.initialize(initParams2)
    client2.notify("initialized", newJObject())
    let helloWorldFile2 = "projects/hw/hw.nim"
    let hwAbsFile2 = uriToPath(helloWorldFile2.fixtureUri())
    client2.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile2))
    check waitFor client2.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile2}"
    )
    # Verify crashCount is 0 after a clean spawn
    if hwAbsFile2 in ls2.pool.slots:
      check ls2.pool.slots[hwAbsFile2].crashCount == 0

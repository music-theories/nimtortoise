import std/[os, strformat, strutils, sequtils, json, options]

import chronos
import unittest2

import ../src/utils/utils
import ./fixhelpers

suite "Fix #7 and #11 — workspace/didRenameFiles":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  client.setWorkspaceConfig(%*[{"maxNimsuggestProcesses": 1}])
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  let widgetFile = "tests/projects/simple/src/widget.nim"

  test "server does not crash after workspace/didRenameFiles":
    echo "    >> server does not crash after workspace/didRenameFiles"
    # Open the project entry point first so its nimsuggest is running.
    # widget.nim will then be assigned to it via isKnownByANimsuggestSlot.
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())
    sendDidOpen(client, widgetFile)
    waitFor sleepAsync(500)

    sendDidRename(client, widgetFile, "tests/projects/simple/src/widget_renamed.nim")
    waitFor sleepAsync(500)

    discard sendHover(client, widgetFile, 7, 5)
    check true
    echo "    >> DONE: server does not crash after workspace/didRenameFiles"

  test "publishDiagnostics clears errors for old URI after rename":
    echo "    >> publishDiagnostics clears errors for old URI after rename"
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr.endsWith("widget.nim") and
        j["diagnostics"].len == 0,
      5000
    )
    echo "    >> DONE: publishDiagnostics clears errors for old URI after rename"

  stopServer(client)

suite "Fix #12A — openFiles sync on didClose":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  client.setWorkspaceConfig(%*[{"maxNimsuggestProcesses": 1}])
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  test "closing one file does not break hover on another file":
    echo "    >> closing one file does not break hover on another file"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())
    sendDidOpen(client, "tests/projects/simple/src/widget.nim")
    waitFor sleepAsync(300)

    client.notify("textDocument/didClose", %* {
      "textDocument": {"uri": fixtureUri("tests/projects/simple/src/widget.nim")}
    })
    waitFor sleepAsync(200)

    discard sendHover(client, "tests/projects/simple/src/simple.nim", 4, 5)
    check true
    echo "    >> DONE: closing one file does not break hover on another file"

  stopServer(client)

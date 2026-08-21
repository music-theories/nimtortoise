import std/[os, strformat, strutils, sequtils, json, options]
import chronos
import unittest2

import ../src/utils/utils
import fixhelpers

suite "Fix #19 — cascade prevention at maxNimsuggestProcesses=1":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  client.setWorkspaceConfig(%*[{
    "maxNimsuggestProcesses": 1,
    "projectMapping": [{"fileRegex": "tests/projects/simple/src/.*\\.nim", "projectFile": simpleProjectFile()}]
  }])
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  test "opening a second unimported file does not cascade-restart into a loop":
    echo "    >> opening a second unimported file does not cascade-restart into a loop"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    sendDidOpen(client, "tests/projects/simple/src/orphan2.nim")
    waitFor sleepAsync(2000)
    check waitForInstanceCount(client, 1, 3000)
    echo "    >> DONE: opening a second unimported file does not cascade-restart into a loop"

  stopServer(client)

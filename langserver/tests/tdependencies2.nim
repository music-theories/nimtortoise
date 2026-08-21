# Tests transitive dependencies

import std/[os, sequtils, json]
import chronos
import chronicles
import unittest2

import ../src/utils/utils
import fixhelpers

const
  depsRoot = "tests/projects/dependencies"
  fileAPath = depsRoot & "/src/dependencies/file_a.nim"
  fileCPath = depsRoot & "/src/dependencies/file_c.nim"
  entryPath = depsRoot & "/src/dependencies.nim"

suite "Transitive dependency diagnostics":
  let (cmdParams, ls, client) = startServer(depsRoot)
  client.setWorkspaceConfig(%*[{"maxNimsuggestProcesses": 1}])
  doInitialize(client, depsRoot)
  client.notify("initialized", newJObject())

  # Open the project entry point first so nimsuggest starts with the full dependency
  # graph, then open the two files under test so they are assigned to the same slot.
  sendDidOpen(client, entryPath)
  check waitForNsInit(client, dependenciesProjectFile())
  sendDidOpen(client, fileAPath)
  sendDidOpen(client, fileCPath)
  waitFor sleepAsync(500)

  test "no type errors to start with":
    echo "    >> no type errors to start with"
    client.calls["textDocument/publishDiagnostics"] = @[]
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        # debug "diagnostics ", diags = $j
        j["uri"].getStr.endsWith("file_c.nim") and j["diagnostics"].len == 0,
      15000
    )
    echo "    >> DONE: no errors to start with"

  test "type error appears in file_c when file_a.field_1 changes to int":
    echo "    >> type error appears in file_c when file_a.field_1 changes to int"
    client.calls["textDocument/publishDiagnostics"] = @[]
    sendDidChange(client, fileAPath, 1,
      "type\n  TypeToTest* = object\n    field_1*: int\n")
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        # debug "diagnostics ", diags = $j
        j["uri"].getStr.endsWith("file_c.nim") and j["diagnostics"].len > 0,
      15000
    )
    echo "    >> DONE: type error appears in file_c when file_a.field_1 changes to int"

  stopServer(client)

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
  client.setWorkspaceConfig(%*[{
    "maxNimsuggestProcesses": 1,
    "performance": "HIGHEST"
  }])
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

  test "error clears in file_c when field_1 is assigned an int":
    echo "    >> error clears in file_c when field_1 is assigned an int"
    client.calls["textDocument/publishDiagnostics"] = @[]
    sendDidChange(client, fileCPath, 1,
      "import file_b\n\nlet testingType* = TypeToTest(\n  field_1: 3\n)\n\n")
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr.endsWith("file_c.nim") and j["diagnostics"].len == 0,
      15000
    )
    echo "    >> DONE: error clears in file_c when field_1 is assigned an int"

  test "error reappears in file_c when file_a.field_1 reverts to string":
    echo "    >> error reappears in file_c when file_a.field_1 reverts to string"
    client.calls["textDocument/publishDiagnostics"] = @[]
    sendDidChange(client, fileAPath, 2,
      "type\n  TypeToTest* = object\n    field_1*: string\n")
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr.endsWith("file_c.nim") and j["diagnostics"].len > 0,
      15000
    )
    echo "    >> DONE: error reappears in file_c when file_a.field_1 reverts to string"

  test "diagnostics persist in file_c after file_a is saved":
    echo "    >> diagnostics persist in file_c after file_a is saved"
    # Save file_a — this should not clear the existing error in file_c
    # (file_c still assigns an int to a string field).
    sendDidSave(client, fileAPath,
      "type\n  TypeToTest* = object\n    field_1*: string\n")
    waitFor sleepAsync(3000)
    let diagsForC = client.calls["textDocument/publishDiagnostics"]
      .filterIt(it["uri"].getStr.endsWith("file_c.nim"))
    check diagsForC.len > 0
    check diagsForC[^1]["diagnostics"].len > 0
    echo "    >> DONE: diagnostics persist in file_c after file_a is saved"

  test "error clears in file_c when field_1 is assigned a string":
    echo "    >> error clears in file_c when field_1 is assigned a string"
    client.calls["textDocument/publishDiagnostics"] = @[]
    sendDidChange(client, fileCPath, 2,
      "import file_b\n\nlet testingType* = TypeToTest(\n  field_1: \"testing\"\n)\n\n")
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr.endsWith("file_c.nim") and j["diagnostics"].len == 0,
      15000
    )
    echo "    >> DONE: error clears in file_c when field_1 is assigned a string"

  stopServer(client)

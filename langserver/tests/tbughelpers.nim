## Shared helpers for tbugs* test files.

import std/[os, json, options]
import chronos

import ./fixhelpers

# rootUri = tests/projects, so tryRelativeTo strips that prefix.
# Regexes are relative to that root.
proc combinedMapping*(): seq[NlsNimsuggestConfig] =
  @[
    NlsNimsuggestConfig(
      fileRegex: "simple/src/.*\\.nim",
      projectFile: simpleProjectFile()
    ),
    NlsNimsuggestConfig(
      fileRegex: "monorepo/pkga/src/.*\\.nim",
      projectFile: pkgaProjectFile()
    ),
    NlsNimsuggestConfig(
      fileRegex: "monorepo/pkgb/src/.*\\.nim",
      projectFile: pkgbProjectFile()
    ),
  ]

proc startCombinedServer*(maxNs: int): (CommandLineParams, LanguageServer, LspSocketClient) =
  generateSimpleNimblePaths()
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects")
  # Build config JSON and register it so the server receives it via
  # workspace/configuration when it processes the initialized notification.
  var mappingArr = newJArray()
  for m in combinedMapping():
    mappingArr.add(%* {"fileRegex": m.fileRegex, "projectFile": m.projectFile})
  let configObj = newJObject()
  configObj["maxNimsuggestProcesses"] = %maxNs
  configObj["projectMapping"] = mappingArr
  let configJson = newJArray()
  configJson.add(configObj)
  client.setWorkspaceConfig(configJson)
  doInitialize(client, "tests/projects")
  client.notify("initialized", newJObject())
  (cmdParams, ls, client)

const
  simpleRel*  = "tests/projects/simple/src/simple.nim"
  widgetRel*  = "tests/projects/simple/src/widget.nim"
  orphanRel*  = "tests/projects/simple/src/orphan.nim"
  orphan2Rel* = "tests/projects/simple/src/orphan2.nim"
  pkgbRel*    = "tests/projects/monorepo/pkgb/src/pkgb.nim"
  pkgaRel*    = "tests/projects/monorepo/pkga/src/pkga.nim"
  aorphanRel* = "tests/projects/monorepo/pkga/src/aorphan.nim"

import std/[options, json, os, strformat]

import chronos
import chronicles
import unittest2

import nimtortoise

import ./[lspsocketclient, client_utils, testhelpers]
# from fixhelpers import stopServer

suite "Nimlangserver extensions":
  let (cmdParameters, ls, client) = startServer()
 
  test "calling extension/suggest with restart in the project uri should restart nimsuggest":
    echo "    >> calling extension/suggest with restart in the project uri should restart nimsuggest"
    let helloWorldDir = FilePathAbs(currentSourcePath().parentDir() / "projects/hw/")
    let hellowWorldDirUri = toUri(helloWorldDir)
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": hellowWorldDirUri,
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)
    client.notify("initialized", newJObject())

    check initializeResult.capabilities.textDocumentSync.isSome

    let helloWorldFile = string(helloWorldDir) / "hw.nim"
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    # Wait for initial nimsuggest spawn.
    let hwAbsFile = FilePathAbs(helloWorldFile)
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
      timeoutMs = 30000,
    )

    # Clear showMessage history so we can detect the post-restart notification.
    client.calls["window/showMessage"] = @[]

    let suggestParams = SuggestParams(action: saRestart, projectFile: $hwAbsFile)
    discard client.call("extension/suggest", %suggestParams).waitFor

    # After the restart the server sends another "Nimsuggest initialized" message.
    # A fresh nimsuggest process must have started; that is the only meaningful
    # observable the API exposes.
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
      timeoutMs = 30000,
    )

  stopServer(client)

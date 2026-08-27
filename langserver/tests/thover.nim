import std/[options, json, jsonutils, sequtils, strutils, sugar, strformat]

import json_rpc/[rpcclient]
import chronicles
import unittest2

import fixhelpers

suite "LSP features":
  let helloWorldUri = fixtureUri("tests/projects/hw/hw.nim")
  let (cmdParams, ls, client) = startServer()
  doInitialize(client, "tests/projects/hw")
  client.notify("initialized", newJObject())
  sendDidOpen(client, "tests/projects/hw/hw.nim")
  discard waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {toFilePathAbs(helloWorldUri)}",
  )

  test "didChange then sending hover.":
    echo "    >> didChange then sending hover."
    let didChangeParams = DidChangeTextDocumentParams %* {
      "textDocument": {
        "uri": helloWorldUri,
        "version": 1
      },
      "contentChanges": [{
          "text": "\nproc a() = discard\na()\n"
        }
      ]
    }
    client.notify("textDocument/didChange", %didChangeParams)
    sleep(1000)
    let hoverParams = positionParams(helloWorldUri, 2, 0)
    let hoverResponse = client.call("textDocument/hover", %hoverParams).waitFor
    check contains($hoverResponse, "hw.a: proc ()")

  stopServer(client)

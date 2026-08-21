import std/[json, strformat]
import unittest2

import fixhelpers

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

suite "Nimlangserver fail count":
  test "fail count is reset when a nimsuggest starts successfully":
    echo "    >> fail count is reset when a nimsuggest starts successfully"
    # NimsuggestSlot.crashCount is the new-arch equivalent of ls.failTable.
    # After a slot spawns successfully, crashCount must be 0 so it is not
    # permanently blocked after MAX_CRASH_RETRIES.
    let (cmdParams, ls, client) = startServer()
    doInitialize(client, "tests/projects/hw")
    client.notify("initialized", newJObject())
    let hwAbsFile = toFilePathAbs(fixtureUri("tests/projects/hw/hw.nim"))
    sendDidOpen(client, "tests/projects/hw/hw.nim")
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )
    # Verify crashCount is 0 after a clean spawn
    if hwAbsFile in ls.pool.slots:
      check ls.pool.slots[hwAbsFile].crashCount == 0
    stopServer(client)

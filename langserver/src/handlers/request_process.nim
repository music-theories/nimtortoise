import std/json
import chronos
import chronicles
import ../langserver/[langserver_types, query_types]

# === initialize ===
# See init_langseerver.nim

# === shutdown ===
proc shutdown*(ls: LanguageServer, input: JsonNode): Future[JsonNode] {.async.} =
  debug "Shutting down"
  let shutdownQuery = LangserverQuery(
    kind: LangserverQueryKind.SHUTDOWN,
    shutdown: newFuture[bool]("shutdown")
  )
  ls.langserverQueue.addLastNoWait(shutdownQuery)
  discard await shutdownQuery.shutdown
  # await ls.pool.stopNimsuggestProcesses()
  ls.isShutdown = true
  # let id = input{"id"}.extractId
  result = newJNull()
  trace "Shutdown complete"

# === exit ===
proc exit*(
  p: tuple[ls: LanguageServer, onExit: OnExitCallback], _: JsonNode
): Future[JsonNode] {.async.} =
  if not p.ls.isShutdown:
    debug "Received an exit request without prior shutdown request"
    discard await p.ls.shutdown(newJNull())
    # await p.ls.pool.stopNimsuggestProcesses()
  debug "Quitting process"
  result = newJNull()
  await p.onExit()

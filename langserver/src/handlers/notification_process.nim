import std/[options, json, times]
import chronos
import chronicles
import ../protocol/types
import ../langserver/langserver

# === initialized ===
# See init_langserver.nim
  
# === $/cancelRequest ===
proc cancelRequest*(ls: LanguageServer, params: CancelParams): Future[void] {.async.} =
  if params.id.isSome:
    let id = params.id.get.getInt.uint
    if id notin ls.messaging.pendingRequests:
      return
    debug "Cancelling: ", id = id
    ls.messaging.pendingRequests[id].state = prsCancelled
    ls.messaging.pendingRequests[id].endTime = now()
    let query = ls.messaging.pendingRequests[id].query
    if query.isSome:
      query.get.cancelled = true
      ## processQueries checks this flag before dispatching the TCP call.
      ## If already dispatched, the in-flight call completes normally with @[].
      ## No future cancellation exception is thrown — handlers get empty results.

# === $/setTrace ===
proc setTrace*(ls: LanguageServer, params: SetTraceParams) {.async.} =
  debug "setTrace", value = params.value


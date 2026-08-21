import std/[options, sets, tables]
import chronos
import chronicles

import ../nimsuggest/nimsuggest
import ./[langserver_types, query_types]

proc processDidCloseQuery*(
  ls: LanguageServer, q: FileAccessQuery
) {.async.} = 
  let uri = q.didClose.textDocument.uri
  debug "Closed the following document:", uri = uri
  let slotCheck = getSlotThatOwnsUri(ls.pool, uri)
  if  uri in ls.files.openFiles and slotCheck.isSome():
    let slotThatOwnsUri = slotCheck.get()
    slotThatOwnsUri.ownedUris.excl(uri)

    # If the slot has no remaining tracked files, shut it down — important for standalone orphan slots.
    debug "Check the amount of owned uris for this slot:", uri = uri, ownedUris = slotThatOwnsUri.ownedUris.len
    if slotThatOwnsUri.ownedUris.len == 0 and ls.pool.slots.len > 1:
      # The ls.pool.slots.len > 1 qualification means that if there is only one slot left, it is persisted, so nimsuggest is not constantly spawning and stopping.
      debug "Stopping this slot:", uri = uri
      discard await stopNimsuggestSlotAndRemoveFromPool(ls.pool, slotThatOwnsUri)
      ls.pool.removeSlot(slotThatOwnsUri.spawnInfo.entryPoint)
      
    ls.files.openFiles.del(uri)

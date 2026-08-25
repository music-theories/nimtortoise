import std/[options, sets, tables]
import chronos
import chronicles
import forest

import ../nimsuggest/nimsuggest
import ./[langserver_types, query_types]

proc isANimbleEntryPoint*(
  nimbleInfo: NimbleInfo,
  uriToCheck: FileUri
): bool = 
  result = false
  let fileToCheck = toFilePathAbs(uriToCheck)
  for e in nimbleInfo.entryPoints:
    if fileToCheck == e:
      return true

proc processDidCloseQuery*(
  ls: LanguageServer, q: FileAccessQuery
) {.async.} = 
  let uri = q.didClose.textDocument.uri
  debug "Closed the following document:", uri = uri
  let slotCheck = getSlotThatOwnsUri(ls.pool, uri)
  if uri in ls.files.openFiles:
    if slotCheck.isSome():
      let slotThatOwnsUri = slotCheck.get()
      slotThatOwnsUri.ownedUris.excl(uri)

      # If the slot has no remaining tracked files, shut it down — important for standalone orphan slots.
      debug "Check the amount of owned uris for this slot:", uri = uri, ownedUris = slotThatOwnsUri.ownedUris.len
      # Check if it is a orphan
      if slotThatOwnsUri.ownedUris.len == 0:
        if ls.pool.slots.len > 1 or not(isANimbleEntryPoint(ls.dependencies.nimble, uri)):
          # The ls.pool.slots.len > 1 qualification means that if there is only one slot left, it is persisted, so nimsuggest is not constantly spawning and stopping.
          debug "Stopping this slot:", uri = uri
          discard await stopNimsuggestSlotAndRemoveFromPool(ls.pool, slotThatOwnsUri)
          ls.pool.removeSlot(slotThatOwnsUri.spawnInfo.entryPoint)

    ls.files.openFiles.del(uri)

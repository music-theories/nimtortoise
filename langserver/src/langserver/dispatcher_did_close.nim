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

      debug "Check the amount of owned uris for this slot:", uri = uri, ownedUris = slotThatOwnsUri.ownedUris.len
      # I decided to remove the setting where a nimsuggest would not stop if there was only one slot left, as this was causing too many edge cases.
      if slotThatOwnsUri.ownedUris.len == 0:
        debug "Stopping this slot:", uri = uri
        discard await stopNimsuggestSlotAndRemoveFromPool(ls.pool, slotThatOwnsUri)

    ls.files.openFiles.del(uri)

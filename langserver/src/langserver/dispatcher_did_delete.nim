import std/[options, sets, strutils, tables]
import chronos
import chronicles

import forest

import ../nimsuggest/nimsuggest
import ../protocol/types
import ../utils/utils
import ./[langserver_types, query_types]

proc processDidDeleteQuery*(
  ls: LanguageServer, q: FileAccessQuery
) {.async.} = 
  for f in q.deleteFiles.files:
    let uri = f.uri
    debug "File deleted", uri = uri
    let path = toFilePathAbs(uri)

    if string(path).endsWith(".nim"):
      ls.dependencies = await initForest(ls.files.rootPath)

    if uri in ls.files.openFiles:
      ls.files.openFiles.del(uri)

      let slotCheck = getSlotThatOwnsUri(ls.pool, uri)
      if slotCheck.isSome():
        let slotThatOwnsUri = slotCheck.get()
        slotThatOwnsUri.ownedUris.excl(uri)
        if slotThatOwnsUri.ownedUris.len == 0:
          discard await ls.pool.stopNimsuggestSlot(slotThatOwnsUri)

        else:
          if string(path).endsWith(".nim"):
            let recompileQuery = NimsuggestQuery[LspFilePosition](
              kind: NimsuggestQueryKind.RECOMPILE,
              uri: toUri(slotThatOwnsUri.spawnInfo.entryPoint),
              dirtyFile: FilePathAbs(""),
              responseFuture: newFuture[seq[Suggest]]("recompile"),
            )
            slotThatOwnsUri.queryMailbox.addLastNoWait(recompileQuery)
      else:
        # Is not owned by a slot - no action needed
        discard

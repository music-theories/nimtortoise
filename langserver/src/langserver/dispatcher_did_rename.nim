import std/[options, sets, strutils, tables, os]
import chronos
import chronicles

import forest

import ../nimsuggest/nimsuggest
import ../protocol/types
import ../utils/utils
import ./[langserver_types, query_types]

proc processDidRenameQuery*(
  ls: LanguageServer, q: FileAccessQuery
) {.async.} = 
  for r in q.renameFiles.files:
    let oldUri = r.oldUri
    let newUri = r.newUri
    debug "File renamed", oldUri = oldUri, newUri = newUri
    let oldStash = uriToStashFilePath(ls.files.storageDir, oldUri)
    let newStash = uriToStashFilePath(ls.files.storageDir, newUri)
    let oldPath = toFilePathAbs(oldUri)
    let newPath = toFilePathAbs(newUri)

    if string(oldStash).fileExists:
      try:
        moveFile(string(oldStash), string(newStash))
      except Exception as e:
        debug "Failed to move stash file on rename",
          oldStash = oldStash, newStash = newStash, msg = e.msg

    if oldUri in ls.files.openFiles:
      let fileInfo = ls.files.openFiles[oldUri]
      let slotCheck = getSlotThatOwnsUri(ls.pool, oldUri)
      if slotCheck.isSome():
        let slotThatOwnsUri = slotCheck.get()
        slotThatOwnsUri.ownedUris.excl(oldUri)
        slotThatOwnsUri.ownedUris.incl(newUri)

        ls.files.openFiles[newUri] = NlsFileInfo(
          fingerTable: fileInfo.fingerTable,
          lastChanged: fileInfo.lastChanged,
          lastChecked: fileInfo.lastChecked,
          textDocument: TextDocumentItem(
            uri: newUri,
            languageId: fileInfo.textDocument.languageId,
            version: fileInfo.textDocument.version,
            text: fileInfo.textDocument.text,
          ),
        )
        ls.files.openFiles.del(oldUri)

        if string(newPath).endsWith(".nim"):
          debug "processCommands: update dependecy tree", entryPoints = slotThatOwnsUri.spawnInfo.entryPoint
          ls.dependencies = await initForest(ls.files.rootPath)

          debug "processCommands: sending recompile", entryPoints = slotThatOwnsUri.spawnInfo.entryPoint
          # RECOMPILE The Nimsuggest Instance
          let recompileQuery = NimsuggestQuery[LspFilePosition](
            kind: NimsuggestQueryKind.RECOMPILE,
            uri: toUri(slotThatOwnsUri.spawnInfo.entryPoint),
            dirtyFile: FilePathAbs(""),
            responseFuture: newFuture[seq[Suggest]]("recompile"),
          )
          slotThatOwnsUri.queryMailbox.addLastNoWait(recompileQuery)

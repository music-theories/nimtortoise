import std/[os, sha1, tables, options]
import chronicles
import ./langserver_types
import ../utils/utils
import ../protocol/types

proc uriStorageLocation*(ls: LanguageServer, uri: FileUri): FilePath =
  # Use SHA-1 for a collision-resistant stash filename (40 hex chars).
  # std/hash is a 64-bit integer hash; two URIs could share it and silently
  # overwrite each other's edit buffer. SHA-1 collision probability is ~2^-80.
  return FilePath(string(ls.files.storageDir) / ($secureHash(string(uri)) & ".nim"))

proc uriToStash*(ls: LanguageServer, uri: FileUri): FilePath =
  if ls.files.openFiles.hasKey(uri):
    return uriStorageLocation(ls, uri)
  else:
    return FilePath("")

proc toUtf16Pos*(
  ls: LanguageServer, uri: FileUri, line: int, utf8Pos: int
): Option[int] =
  if uri in ls.files.openFiles and line >= 0 and line < ls.files.openFiles[uri].fingerTable.len:
    let utf16Pos = ls.files.openFiles[uri].fingerTable[line].utf8to16(utf8Pos)
    return some(utf16Pos)
  else:
    return none(int)

proc getCharacter*(
  ls: LanguageServer, uri: FileUri, line: int, character: int
): Option[int] =
  if uri in ls.files.openFiles and line < ls.files.openFiles[uri].fingerTable.len:
    return some ls.files.openFiles[uri].fingerTable[line].utf16to8(character)
  else:
    return none(int)

proc getRootPath*(params: LspInitializeParams): Option[FilePath] = 
  if params.rootUri.isSome():
    let rootUri: FileUri = params.rootUri.get()
    if string(rootUri).len > 0:
      let path = uriToPath(rootUri)
      debug "getRootPath: rootUri on LSPInitializeParams found ", path = path
      return some(path)
    else:
      debug "getRootPath: rootUri on LSPInitializeParams is none()."
      return none(FilePath)
  else:
    let rootPathParam = params.rootPath
    if rootPathParam.isSome():
      let rootPath = rootPathParam.get()
      if string(rootPath).len > 0:
        let path = toFilePath(normalizedPath(rootPath))
        debug "getRootPath: rootUri on LSPInitializeParams found ", path = path
        return some(path)
      else:
        debug "getRootPath: rootPath on LSPInitializeParams has length 0."
      return none(FilePath)

    else:
      debug "getRootPath: rootPath on LSPInitializeParams is none."
      return none(FilePath)

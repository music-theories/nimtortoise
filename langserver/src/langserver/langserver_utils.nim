import std/[os, tables, options]
import chronicles
import forest
import ./langserver_types
import ../utils/utils
import ../protocol/types

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

proc getRootPath*(params: LspInitializeParams): Option[DirPathAbs] =
  if params.rootUri.isSome():
    let rootUri: FileUri = params.rootUri.get()
    if string(rootUri).len > 0:
      let path = toDirPathAbs(rootUri)
      debug "getRootPath: rootUri on LSPInitializeParams found ", path = path
      return some(path)
    else:
      debug "getRootPath: rootUri on LSPInitializeParams is none()."
      return none(DirPathAbs)
  else:
    let rootPathParam = params.rootPath
    if rootPathParam.isSome():
      let rootPath = rootPathParam.get()
      if rootPath.len > 0:
        let path = DirPathAbs(normalizedPath(rootPath))
        debug "getRootPath: rootUri on LSPInitializeParams found ", path = path
        return some(path)
      else:
        debug "getRootPath: rootPath on LSPInitializeParams has length 0."
      return none(DirPathAbs)
    else:
      debug "getRootPath: rootPath on LSPInitializeParams is none."
      return none(DirPathAbs)

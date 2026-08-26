import std/[jsconsole, jsffi, sequtils, strformat, hashes, strutils]
import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[jsNode, jsNodePath, jsString, jsNodeFs, jsNodeCp, jsNodeOs]
import ./[vscode_state_types]

# import std/jsffi
# import mapIt, foldl, filterIt, concat
# import nimUtils

proc getAugmentedEnv*(): JsAssoc[cstring, cstring] =
  ## Returns a copy of process.env with ~/.nimble/bin prepended to PATH.
  ## This ensures child processes can find nim/nimble/nimlangserver even
  ## when VSCode was launched from the Dock without a full shell PATH.
  let userHomeVarName = if process.platform == "win32": "USERPROFILE" else: "HOME"
  let augmentedPath =
    path.join(process.env[userHomeVarName], ".nimble", "bin") &
    path.delimiter &
    process.env["PATH"]
  let env = newJsAssoc[cstring, cstring]()
  for key, val in process.env.pairs():
    env[key] = val
  env["PATH"] = augmentedPath
  return env

proc isValidLspPath(lspPath: cstring): bool =
  result = not lspPath.isNil and lspPath != "" and fs.existsSync(path.resolve(lspPath))
  if lspPath.isNil:
    console.log("lspPath is nil")
  else:
    console.log(fmt"isValidLspPath({lspPath}) = {result}".cstring)

proc getLocalLspDir(): cstring =
  #The lsp is installed inside the user directory because the user 
  #storage of the extension seems to be too long and the installation fails
  result = path.join(nodeOs.homedir, ".vscode-nim-tortoise")
  if not fs.existsSync(result):
    fs.mkdirSync(result)


var binPathsCache = newMap[cstring, cstring]()
proc getBinPath(
  tool: cstring, 
  initialSearchPaths: openArray[cstring] = []
): cstring =
  if binPathsCache[tool].toJs().to(bool):
    return binPathsCache[tool]
  if not process.env["PATH"].isNil():
    # USERPROFILE is the standard equivalent of HOME on windows.
    let userHomeVarName = if process.platform == "win32": "USERPROFILE" else: "HOME"

    # add support for choosenim
    let fullEnvPath =
      path.join(process.env[userHomeVarName], ".nimble", "bin") & path.delimiter &
      process.env["PATH"]

    let pathParts: seq[cstring] =
      concat(@initialSearchPaths, fullEnvPath.split(path.delimiter))

    let endings =
      if process.platform == "win32":
        @[".exe", ".cmd", ""]
      else:
        @[""]

    let paths = pathParts
      .mapIt(
        block:
          var dir = it
          endings.mapIt(path.join(dir, tool & cstring(it)))
      )
      .foldl(a & b)
      # flatten nested arays
      .filterIt(fs.existsSync(it))

    if paths.len == 0:
      return nil

    binPathsCache[tool] = paths[0]
    if process.platform != "win32":
      try:
        var nimPath: cstring
        case $(process.platform)
        of "darwin":
          nimPath =
            cp.execFileSync("readlink", @[binPathsCache[tool]]).toString().strip()
          if nimPath.len > 0 and not path.isAbsolute(nimPath):
            nimPath =
              path.normalize(path.join(path.dirname(binPathsCache[tool]), nimPath))
        of "linux":
          nimPath = cp
            .execFileSync("readlink", @[cstring("-f"), binPathsCache[tool]])
            .toString()
            .strip()
        else:
          nimPath =
            cp.execFileSync("readlink", @[binPathsCache[tool]]).toString().strip()

        if nimPath.len > 0:
          binPathsCache[tool] = nimPath
      except:
        discard #ignore
  binPathsCache[tool]

proc getLspPath*(state: ExtensionState): (cstring, LSPInstallPathKind) =
  #[
    We first try to use the path from the nim.lsp.path setting.
    If path is not set, we try to use the local nimlangserver binary.
    If the local binary is not found, we try to use the global nimlangserver binary.
  ]#
  var lspPath = vscode.workspace.getConfiguration("nimTortoise").getStr("lsp.path")
  if lspPath.isValidLspPath:
    return (lspPath, lspPathSetting)
  var langserverExec: cstring = "nimtortoise"
  if process.platform == "win32":
    langserverExec.add ".cmd"
  lspPath = path.join(getLocalLspDir(), "nimbledeps", "bin", langserverExec)
  if isValidLspPath(lspPath):
    return (lspPath, lspPathLocal)
  lspPath = getBinPath("nimtortoise")
  if isValidLspPath(lspPath):
    return (lspPath, lspPathGlobal)
  return ("".cstring, lspPathInvalid)


# === MORE ===


proc isSubpath(parent, child: cstring): bool =
  result =
    if process.platform == "win32":
      child.toLowerAscii.startsWith(parent.toLowerAscii)
    else:
      child.startsWith(parent.toLowerAscii)

proc isWorkspaceFile*(filePath: cstring): bool =
  ## Returns true if filePath is related to any workspace file
  ## assumes filePath is absolute

  if vscode.workspace.workspaceFolders.toJs().to(bool):
    return vscode.workspace.workspaceFolders.anyIt(
      it.uri.scheme == "file" and isSubpath(it.uri.fsPath, filePath)
    )
  else:
    return false

proc removeDirSync(p: cstring): void =
  if fs.existsSync(p):
    for entry in fs.readdirSync(p):
      var curPath = path.resolve(p, entry)
      if fs.lstatSync(curPath).isDirectory():
        removeDirSync(curPath)
      else:
        fs.unlinkSync(curPath)
    fs.rmdirSync(p)

proc getDirtyFileFolder*(state: ExtensionState,  nimsuggestPid: cint): cstring =
  path.join(state.ctx.storagePath, "vscodenimdirty_" & cstring($nimsuggestPid))

proc cleanupDirtyFileFolder*(state: ExtensionState,nimsuggestPid: cint) =
  removeDirSync(getDirtyFileFolder(state, nimsuggestPid))

proc getDirtyFile*(state: ExtensionState, nimsuggestPid: cint, filepath, content: cstring): cstring =
  ## temporary file path of edited document
  ## for each nimsuggest instance each file has a unique dirty file
  var dirtyFilePath = path.normalize(
    path.join(getDirtyFileFolder(state, nimsuggestPid), cstring($int(hash(filepath))) & ".nim")
  )
  fs.writeFileSync(dirtyFilePath, content)
  return dirtyFilePath

proc getDirtyFile*(state: ExtensionState, doc: VscodeTextDocument): cstring =
  ## temporary file path of edited document
  ## returns always the same file, so it shouldn't
  ## be used for nimsuggest, only nimpretty!
  var dirtyFilePath =
    path.normalize(path.join(state.ctx.storagePath, "vscodenimdirty.nim"))
  fs.writeFileSync(dirtyFilePath, doc.getText())
  return dirtyFilePath

proc quoteOnlyWin*(path: cstring): cstring =
  result = path
  if process.platform == "win32":
    result = cstring("\"" & ($path).replace("\"", "\\\"") & "\"")

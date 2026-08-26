import std/[jsffi, strutils, options]
import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[jsNode, jsNodePath, jsNodeFs, jsNodeOs]

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


proc expandPath(p: cstring): cstring =
  if ($p).startsWith("~"):
    path.join(nodeOs.homedir, cstring(($p)[1..^1]))
  else:
    p

proc quoteOnlyWin(path: cstring): cstring =
  result = path
  if process.platform == "win32":
    result = cstring("\"" & ($path).replace("\"", "\\\"") & "\"")

proc getLspShellCommand*(): Option[cstring] =
  result = none(cstring)
  let lspPath = vscode.workspace.getConfiguration("nimTortoise").getStr("lsp.path")
  if lspPath.isNil:
    return none(cstring)
  if lspPath == "":
    return none(cstring)
  let resolvedPath: cstring = path.resolve(expandPath(lspPath))
  if fs.existsSync(resolvedPath):
    return some(resolvedPath.quoteOnlyWin())

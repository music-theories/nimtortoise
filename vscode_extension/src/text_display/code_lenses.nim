import std/[strutils, options, sequtils]
import api
import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[jsNodePath]

proc parseIconPath(vscode: Vscode, iconPath: cstring): VscodeUri {.importjs: "#.Uri.parse(#)".}

proc lineAsTask(nimbleTasks: seq[NimbleTask], lineText: string): Option[cstring] =
  result = none(cstring)
  try:
    let taskName = lineText.split(" ")[1].split(",")[0].cstring
    if taskName in nimbleTasks.mapIt(cstring(it.name)):
      return some(taskName)
  except: discard

proc provideNimbleTasksCodeLenses*(
  nimbleTasks: seq[NimbleTask],
  document: VscodeTextDocument, 
  token: VscodeCancellationToken
): seq[VscodeCodeLens] =
  result = @[]
  if not ($document.fileName).endsWith(".nimble"):
    return @[]
  var line = 0
  let text = $document.getText()
  # TODO parse this properly
  for lineText in text.split("\n"):
    let taskName = lineAsTask(nimbleTasks, lineText)
    if taskName.isSome():
      let codeLensRange = vscode.newRange(
        cint(line), cint(0), cint(line), cint(0)
      )
      let command = VscodeCommands()
      let dirPath = path.dirname(document.fileName)
      command.command = "nimTortoise.onNimbleTask"
      command.title = "$(play-circle) Run task"
      command.arguments = @[taskName.get().toJs(), dirPath.toJs()]
      result.add(vscode.newCodeLens(
        codeLensRange, command
      ))
    inc line

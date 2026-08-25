## Types for extension state, this should either get fleshed out or removed
import std/[options, times, strutils, jsconsole, tables, times]
import api
import ../platform/vscodeApi
from ../platform/languageClientApi import VscodeLanguageClient
import ./[vscode_state_types]

proc getNimCmd*(state: ExtensionState): cstring =
  if state.nimDir == "":
    "nim ".cstring
  else:
    (state.nimDir & "/nim ").cstring

proc getTaskByName*(
  state: ExtensionState, 
  name: cstring, 
  projectDir: cstring = ""
): Option[NimbleTask] =
  for task in state.nimbleTasks:
    if task.name == name and (projectDir == "" or task.projectDir == projectDir):
      return some task
  none(NimbleTask)

proc markTaskAsRunning*(
  state: ExtensionState, name: cstring, projectDir: cstring, isRunning: bool
) =
  for task in state.nimbleTasks.mitems:
    if task.name == name and task.projectDir == projectDir:
      task.isRunning = isRunning
      break

proc onExtensionReady*(state: ExtensionState) =
  if state.extensionReady:
    return
  state.extensionReady = true
  for hook in state.onExtensionReadyHooks:
    hook()

proc padStart(len: cint, input: cstring): cstring =
  var output = cstring("0").repeat(input.len)
  return output & input

proc cleanDateString(date: DateTime): cstring =
  var year = date.getFullYear()
  var month = padStart(2, cstring($(date.getMonth())))
  var dd = padStart(2, cstring($(date.getDay())))
  var hour = padStart(2, cstring($(date.getHours())))
  var minute = padStart(2, cstring($(date.getMinutes())))
  var second = padStart(2, cstring($(date.getSeconds())))
  var milliseconds = padStart(3, cstring($(date.getMilliseconds())))
  return cstring(fmt"{year}-{month}-{dd} {hour}:{minute}:{second}.{milliseconds}")

proc outputLine*(state: ExtensionState, message: cstring): void =
  ## Prints message in Nim's output channel
  state.channel.appendLine(fmt"{cleanDateString(newDate())} - {message}".cstring)

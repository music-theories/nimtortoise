## Types for extension state, this should either get fleshed out or removed
import std/[options, times, strformat]
import api
import resources/resources
import ../platform/vscodeApi
import ./[vscode_state_types]

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

proc outputLine*(state: ExtensionState, message: cstring): void =
  ## Prints message in Nim's output channel
  let dateStr = format(now(), "yyyy-MM-dd HH:mm:ss'.'fff")
  state.channel.appendLine(fmt"{dateStr} - {message}".cstring)

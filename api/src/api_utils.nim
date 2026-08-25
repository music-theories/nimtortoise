import std/[json, strutils, jsffi]

import forest
import ./[api_types]

proc toExtensionCommandRequest*(
  params: ExecuteCommandRequestParams
): ExtensionCommandRequest =
  case params.command
  of $(SERVER_STATUS):
    return ExtensionCommandRequest(kind: SERVER_STATUS)
  of $(SERVER_CAPABILITIES):
    return ExtensionCommandRequest(kind: SERVER_CAPABILITIES)
  of $(SERVER_RESTART):
    return ExtensionCommandRequest(kind: SERVER_RESTART)

  of $(NIMSUGGEST_RESTART_ALL):
    return ExtensionCommandRequest(kind: NIMSUGGEST_RESTART_ALL)
  of $(NIMSUGGEST_RESTART):
    let slotString = 
      if "slot" in params.arguments: params.arguments["slot"].getStr()
      else: ""
    return ExtensionCommandRequest(
      kind: NIMSUGGEST_RESTART,
      slot: FilePathAbs(slotString)
    )
  of $(NIMSUGGEST_RECOMPILE):
    let slotString = 
      if "slot" in params.arguments: params.arguments["slot"].getStr()
      else: ""
    return ExtensionCommandRequest(
      kind: NIMSUGGEST_RECOMPILE,
      slot: FilePathAbs(slotString)
    )
  of $(NIMSUGGEST_CHECK_PROJECT):
    let slotString = 
      if "slot" in params.arguments: params.arguments["slot"].getStr()
      else: ""
    return ExtensionCommandRequest(
      kind: NIMSUGGEST_CHECK_PROJECT,
      slot: FilePathAbs(slotString)
    )
  of $(NIMSUGGEST_STOP):
    let slotString = 
      if "slot" in params.arguments: params.arguments["slot"].getStr()
      else: ""
    return ExtensionCommandRequest(
      kind: NIMSUGGEST_STOP,
      slot: FilePathAbs(slotString)
    )
  of $(NIMBLE_LIST_TASKS):
    return ExtensionCommandRequest(
      kind: NIMBLE_LIST_TASKS
    )
  of $(NIMBLE_RUN_TASK):
    var commandValue: seq[string] = @[]
    if "command" in params.arguments: 
      for c in params.arguments["command"].getElems():
        commandValue.add(c.getStr())

    let workingDir = 
      if "workingDir" in params.arguments:  params.arguments["workingDir"].getStr()
      else: ""

    return ExtensionCommandRequest(
      kind: NIMBLE_RUN_TASK,
      nimbleRunTask: NimbleRunTaskRequest(
        command: commandValue,
        workingDir: DirPathAbs(workingDir)
      )
    )
  of $(NIM_MACRO_EXPAND):
    # TODO
    return ExtensionCommandRequest(kind: NIM_MACRO_EXPAND)

func getAllServerCapabilities*(): seq[LspExtensionCapability] = 
  return @[
    SERVER_STATUS,
    SERVER_CAPABILITIES,
    SERVER_RESTART,
    NIMSUGGEST_RESTART_ALL,
    NIMSUGGEST_RECOMPILE,
    NIMSUGGEST_RESTART,
    NIMSUGGEST_STOP,
    NIMSUGGEST_CHECK_PROJECT,
    NIMBLE_LIST_TASKS,
    NIMBLE_RUN_TASK,
    NIM_MACRO_EXPAND
  ]

func serverCapabilitiesToEndpoints*(): seq[string] = 
  result = @[]
  let capabilities = getAllServerCapabilities()
  for c in capabilities:
    result.add("nimTortoise." & $(c))

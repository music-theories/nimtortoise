import std/[os, osproc, sequtils, sets, streams, strformat, strutils, times, deques, options, json]

import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils

import ../configurations/configurations
import ../protocol/[enums, types]
import ../utils/utils
import ../utils/process_utils
import ../nimble/nimscript_utils
import ./[suggestapi_utils, suggestapi_types]

proc detectNimsuggestVersion(
  root: FilePath, 
  nimsuggestPath: FilePath, 
  workingDir: FilePath
): int {.gcsafe.} =
  var process = startProcess(
    command = string(nimsuggestPath),
    workingDir = string(workingDir),
    args = @[string(root), "--info:protocolVer"],
    options = {poUsePath},
  )
  var l: string
  if not process.outputStream.readLine(l):
    l = ""
  var exitCode = process.waitForExit()
  if exitCode != 0 or l == "":
    # older versions of NimSuggest don't support the --info:protocolVer option
    # use protocol version 3 with them
    return 3
  else:
    return parseInt(l)

proc getNimsuggestCapabilities*(
  nimsuggestPath: string
): set[NimSuggestCapability] {.gcsafe.} =
  proc parseCapability(c: string): Option[NimSuggestCapability] =
    debug "Parsing nimsuggest capability", capability = c
    try:
      result = some(parseEnum[NimSuggestCapability](c))
    except:
      debug "Capability not supported. Ignoring.", capability = c
      result = none(NimSuggestCapability)

  var process = startProcess(
    command = nimsuggestPath, args = @["--info:capabilities"], options = {poUsePath}
  )
  var l: string
  if not process.outputStream.readLine(l):
    l = ""
  var exitCode = process.waitForExit()
  if exitCode == 0:
    # older versions of NimSuggest don't support the --info:capabilities option
    for cap in l.split(" ").mapIt(parseCapability(it)):
      if cap.isSome:
        result.incl(cap.get)

proc buildNimsuggestArguments*(
  fileToRun: FilePath,
  protocolVersion: int, 
  capabilities: set[NimSuggestCapability],
  enableExceptionInlayHints: bool,
  enableLog: bool,
): seq[string] =
  let isNimble = string(fileToRun).endsWith(".nimble")
  let isNimScript = string(fileToRun).endsWith(".nims") or isNimble

  var extraArgs = newSeq[string]()
  if isNimScript:
    extraArgs.add("--import: system/nimscript")
  # Nimsuggest crashes when including the file. 
  if isNimble:
    let nimScriptApiPath = getNimScriptAPITemplatePath()
    extraArgs.add("--include: " & nimScriptApiPath)

  var protocolToUse = protocolVersion
  if protocolVersion > HighestSupportedNimSuggestProtocolVersion:
    protocolToUse = HighestSupportedNimSuggestProtocolVersion
  result = @[string(fileToRun), "--v" & $protocolToUse, "--autobind"] & extraArgs
  
  if protocolToUse >= 4:
    result.add("--clientProcessId:" & $getCurrentProcessId())
  
  if enableLog:
    result.add("--log")

  if nsExceptionInlayHints in capabilities:
    if enableExceptionInlayHints:
      result.add("--exceptionInlayHints:on")
    else:
      result.add("--exceptionInlayHints:off")

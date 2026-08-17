import std/[os, osproc, sequtils, sets, streams, strformat, strutils, times, deques, options, json]

import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils

import forest

import ../configurations/configurations
import ../protocol/[enums, types]
import ../utils/utils
import ../utils/process_utils
import ../nimble/nimscript_utils
import ./[suggestapi_utils, suggestapi_types]

proc getNimSuggestPath*(
  nimInfo: NimInfo, conf: NlsConfig 
): Future[FilePathAbs] {.async.} =
  let nimsuggestPath = expandTilde(string(conf.nimsuggestPath))
  if nimsuggestPath.len > 0:
    debug "findNimsuggestPathAndVersion: Using nimsuggest", 
      path = nimsuggestPath
    return FilePathAbs(nimsuggestPath)

  elif string(nimInfo.nimExe) != "":
    let nimDir = parentDir(nimInfo.nimExe)
    if dirExists(string(nimDir)):
      let derivedNimuggestPath = string(nimDir) / "nimsuggest".addFileExt(ExeExt)
      debug "findNimsuggestPathAndVersion: Found nim directory.", path = nimDir
      if fileExists(derivedNimuggestPath):
        debug "findNimsuggestPathAndVersion: Found nimsuggest.", path = derivedNimuggestPath
        return FilePathAbs(string(nimDir) / "nimsuggest".addFileExt(ExeExt))
        
    debug "findNimsuggestPathAndVersion: Could not find nimsuggest via nimDir.  Searching using findExe"
    let findExeNimsuggestPath = findExe("nimsuggest")
    if findExeNimsuggestPath.len > 0:
      debug "findNimsuggestPathAndVersion: found nimsuggest using findExe(). ", 
        path = findExeNimsuggestPath
      return FilePathAbs(findExeNimsuggestPath)

    else:
      let nimbleBinPath = getHomeDir() / ".nimble" / "bin" / "nimsuggest".addFileExt(ExeExt)
      debug "findNimsuggestPathAndVersion: used findExe() to look for nimsuggest but couldn't find it. Looking in homeDir ", location = nimbleBinPath
      # Fallback for restricted PATH environments (e.g. Dock launch on macOS where
      # PATH is /usr/bin:/bin:/usr/sbin:/sbin and ~/.nimble/bin is not included,
      # or Linux desktop launches that only source ~/.profile). Uses ExeExt so
      # the check works on Windows ("nimsuggest.exe") too.
      if fileExists(nimbleBinPath):
        debug "findNimsuggestPathAndVersion: found nimsuggest in homeDir ", location = nimbleBinPath
        return FilePathAbs(nimbleBinPath)
      else:
        debug "findNimsuggestPathAndVersion: Could not locate nimsuggest "
        return FilePathAbs("")


proc getNimsuggestProtocolVersion*(
  nimsuggestPath: FilePathAbs,
): int {.gcsafe.} =
  var process = startProcess(
    command = string(nimsuggestPath),
    args = @["--info:protocolVer"],
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
  nimsuggestPath: FilePathAbs
): set[NimSuggestCapability] {.gcsafe.} =
  proc parseCapability(c: string): Option[NimSuggestCapability] =
    debug "Parsing nimsuggest capability", capability = c
    try:
      result = some(parseEnum[NimSuggestCapability](c))
    except:
      debug "Capability not supported. Ignoring.", capability = c
      result = none(NimSuggestCapability)

  var process = startProcess(
    command = string(nimsuggestPath), args = @["--info:capabilities"], options = {poUsePath}
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

  # protocolVersion: int, 
  # capabilities: set[NimSuggestCapability],

proc buildNimsuggestArguments*(
  spawningInfo: NimsuggestSpawnInfo,
  nimsuggestSettings: NimsuggestSettings,
  enableExceptionInlayHints: bool,
  enableLog: bool,
): seq[string] =
  let entryPoint = spawningInfo.entryPoint
  let isNimble = string(entryPoint).endsWith(".nimble")
  let isNimScript = string(entryPoint).endsWith(".nims") or isNimble

  var extraArgs = newSeq[string]()
  if isNimScript:
    extraArgs.add("--import: system/nimscript")

  if isNimble:
    let nimScriptApiPath = getNimScriptAPITemplatePath()
    extraArgs.add("--include: " & nimScriptApiPath)

  var protocolToUse = nimsuggestSettings.protocol
  if nimsuggestSettings.protocol > HighestSupportedNimSuggestProtocolVersion:
    protocolToUse = HighestSupportedNimSuggestProtocolVersion
  result = @[string(entryPoint), "--v" & $protocolToUse, "--autobind"] & extraArgs
  
  if protocolToUse >= 4:
    result.add("--clientProcessId:" & $getCurrentProcessId())
  
  if enableLog:
    result.add("--log")

  if nsExceptionInlayHints in nimsuggestSettings.capabilities:
    if enableExceptionInlayHints:
      result.add("--exceptionInlayHints:on")
    else:
      result.add("--exceptionInlayHints:off")

  debug "Nim Paths ", paths = spawningInfo.paths

  for p in spawningInfo.paths:
    result.add($(p))

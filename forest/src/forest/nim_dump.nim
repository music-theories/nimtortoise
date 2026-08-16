import std/[os, options, json, tables, sequtils, osproc, streams]
import chronicles
import ./[forest_types, forest_utils]
import ../resources/resources

proc fromNimDumpJson*(j: JsonNode): NimDumpInfo =
  result.version        = j{"version"}.getStr()
  result.nimExe         = FilePathAbs(j{"nimExe"}.getStr())
  result.prefixDir      = DirPathAbs(j{"prefixdir"}.getStr())
  result.libPath        = DirPathAbs(j{"libpath"}.getStr())
  result.projectPath    = DirPathAbs(j{"project_path"}.getStr())
  result.definedSymbols = j{"defined_symbols"}.getElems().mapIt(it.getStr())
  result.libPaths       = j{"lib_paths"}.getElems().mapIt(DirPathAbs(it.getStr()))
  result.lazyPaths      = j{"lazyPaths"}.getElems().mapIt(DirPathAbs(it.getStr()))
  result.outDir         = DirPathAbs(j{"outdir"}.getStr())
  result.`out`          = j{"out"}.getStr()
  result.nimCache       = DirPathAbs(j{"nimcache"}.getStr())
  for k, v in j{"hints"}.pairs():
    result.hints[k] = v.getBool()
  for k, v in j{"warnings"}.pairs():
    result.warnings[k] = v.getBool()

proc startNimDump(nimFile: FilePathAbs): Option[Process] =
  if not fileExists(string(nimFile)):
    debug "nim file does not exist", nimFile = $nimFile
    return none(Process)
  let workingDir = parentDir(nimFile)
  debug "running nim dump", nimFile = $nimFile
  return some(startProcess(
    "nim", workingDir = string(workingDir),
    args = @[
      "dump",
      "--dump.format:json",
      "--noNimblePath",
      "--hints:off",
      "--warnings:off",
      string(nimFile)
    ],
    options = {poUsePath}
  ))

proc collectNimDump(p: Process, nimFile: FilePathAbs): Option[NimDumpInfo] =
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  p.close()
  if exitCode != 0:
    warn "nim dump failed", nimFile = $nimFile, exitCode = exitCode
    return none(NimDumpInfo)
  # nim dump --dump.format:json writes JSON to stdout; hints/warnings go to stderr (not captured);
  # find the JSON object in the output
  let jsonStart = output.find('{')
  if jsonStart < 0:
    warn "nim dump: no JSON found in output", nimFile = $nimFile
    return none(NimDumpInfo)
  try:
    return some(fromNimDumpJson(parseJson(output[jsonStart .. ^1])))
  except JsonParsingError as e:
    warn "failed to parse nim dump JSON", err = e.msg
    return none(NimDumpInfo)

proc getNimDumpInfo*(nimFile: FilePathAbs): Option[NimDumpInfo] =
  ## Runs `nim dump --dump.format:json` on nimFile and parses the result.
  let maybeProcess = startNimDump(nimFile)
  if maybeProcess.isNone:
    return none(NimDumpInfo)
  collectNimDump(maybeProcess.get(), nimFile)

proc getNimDumpInfoForEntryPoints*(
  entryPoints: seq[FilePathAbs], rootPath: DirPathAbs
): Table[FilePathAbs, NimDumpInfo] =
  result = initTable[FilePathAbs, NimDumpInfo]()

  # Phase 1: launch all subprocesses (non-blocking)
  var running: seq[(FilePathAbs, Process)]
  for entryPoint in entryPoints:
    let maybeProcess = startNimDump(entryPoint)
    if maybeProcess.isSome:
      running.add((entryPoint, maybeProcess.get()))
    else:
      warn "nim dump failed, skipping search paths", entryPoint = $entryPoint

  # Phase 2: collect results — all processes already running in parallel
  for (entryPoint, p) in running:
    let info = collectNimDump(p, entryPoint)
    if info.isNone:
      warn "nim dump failed, skipping search paths", entryPoint = $entryPoint
    else:
      result[entryPoint] = info.get()

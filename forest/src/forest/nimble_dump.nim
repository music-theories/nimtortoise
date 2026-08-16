import std/[os, sequtils, options, json, osproc, streams, tables]
import chronos
import chronicles
import ../resources/resources
import ./[forest_utils, forest_types]

proc fromNimbleDumpJson*(j: JsonNode): NimbleDumpInfo =
  result.name         = j{"name"}.getStr()
  result.version      = j{"version"}.getStr()
  result.nimblePath   = FilePathAbs(j{"nimblePath"}.getStr())
  result.author       = j{"author"}.getStr()
  result.desc         = j{"desc"}.getStr()
  result.license      = j{"license"}.getStr()
  result.skipDirs     = j{"skipDirs"}.getElems().mapIt(it.getStr())
  result.skipFiles    = j{"skipFiles"}.getElems().mapIt(it.getStr())
  result.skipExt      = j{"skipExt"}.getElems().mapIt(it.getStr())
  result.installDirs  = j{"installDirs"}.getElems().mapIt(DirPathRel(it.getStr()))
  result.installFiles = j{"installFiles"}.getElems().mapIt(FilePathRel(it.getStr()))
  result.installExt   = j{"installExt"}.getElems().mapIt(it.getStr())
  for req in j{"requires"}.getElems():
    result.requires.add NimbleRequire(
      name: req{"name"}.getStr(),
      str:  req{"str"}.getStr(),
      ver:  NimbleVer(
        kind: req{"ver"}{"kind"}.getStr(),
        ver:  req{"ver"}{"ver"}.getStr()
      )
    )
  result.bin          = j{"bin"}.getElems().mapIt(it.getStr())
  result.binDir       = DirPathRel(j{"binDir"}.getStr())
  result.srcDir       = DirPathRel(j{"srcDir"}.getStr())
  result.backend      = j{"backend"}.getStr()
  result.paths        = j{"paths"}.getElems().mapIt(DirPathAbs(it.getStr()))
  result.nimDir       = DirPathAbs(j{"nimDir"}.getStr())
  result.entryPoints  = j{"entryPoints"}.getElems().mapIt(FilePathRel(it.getStr()))
  result.testEntryPoint = FilePathRel(j{"testEntryPoint"}.getStr())

proc getNimbleDumpInfo*(nimbleFile: FilePathAbs): Future[Option[NimbleDumpInfo]] {.async.} =
  ## Runs nimble dump --json to get project metadata.
  if not fileExists(string(nimbleFile)):
    debug "nimble file does not exist", nimbleFile = $nimbleFile
    return none(NimbleDumpInfo)
  let workingDir = parentDir(nimbleFile)
  debug "running nimble dump --json", workingDir = $workingDir
  let p = startProcess("nimble", workingDir = string(workingDir),
                       args = @["dump", "--json"],
                       options = {poUsePath})
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  p.close()
  if exitCode != 0:
    warn "nimble dump --json failed", workingDir = $workingDir, exitCode = exitCode
    return none(NimbleDumpInfo)
  debug "nimble dump succeeded, output length", len = output.len
  try:
    return some(fromNimbleDumpJson(parseJson(output)))
  except JsonParsingError as e:
    warn "failed to parse nimble dump JSON", err = e.msg
    return none(NimbleDumpInfo)

proc getAllNimbleFileInfo*(allNimbleFiles: seq[FilePathAbs]): Future[Table[FilePathAbs, NimbleDumpInfo]] {.async.} = 
  result = initTable[FilePathAbs, NimbleDumpInfo]()
  for nimbleFile in allNimbleFiles:
    let nimbleDir = parentDir(nimbleFile)
    let dumpInfo = waitFor getNimbleDumpInfo(nimbleFile)
    if dumpInfo.isNone:
      warn "nimble dump failed, skipping", nimbleFile = $nimbleFile
      continue
    
    result[nimbleFile] = dumpInfo.get()

proc getEntryPoints*(
  nimbleFiles: Table[FilePathAbs, NimbleDumpInfo]
): seq[FilePathAbs] = 
  result = @[]
  for k, nimbleFile in nimbleFiles:
    # Collect all entry points for this package (resolved to absolute paths).
    let nimbleDir = parentDir(k)
    for ep in nimbleFile.entryPoints:
      # let nimbleDir = parentDir(ep)
      let abs = FilePathAbs((string(nimbleDir) / string(ep)).absolutePath.normalizedPath)
      if fileExists(string(abs)):
        result.add(abs)
      else:
        warn "entry point not found, skipping", path = $abs

    if string(nimbleFile.testEntryPoint).len > 0:
      let abs = FilePathAbs((string(nimbleDir) / string(nimbleFile.testEntryPoint)).absolutePath.normalizedPath)
      if fileExists(string(abs)):
        result.add(abs)
  
  result = deduplicate(result)
  

proc initNimbleInfo*(
  rootPath: DirPathAbs
): Future[NimbleInfo] {.async.} = 
  let allNimbleFiles = getAllFiles(rootPath, "*.nimble")
  let nimbleDumpTable = await getAllNimbleFileInfo(allNimbleFiles)
  let allEntryPoints = getEntryPoints(nimbleDumpTable)
  return NimbleInfo(
    files: allNimbleFiles,
    dump: nimbleDumpTable,
    entryPoints: allEntryPoints
  )

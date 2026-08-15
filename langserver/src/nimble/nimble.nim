import std/[os, sequtils, strutils, tables, options, strscans]
import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils

import ../protocol/types
import ../utils/process_utils
import ../utils/utils

import ./[nimble_types, nimble_utils]

proc getNimbleDumpInfo*(
  nimbleDumpCache: Table[FilePath, NimbleDumpInfo],
  nimbleFile: FilePath
): Future[NimbleDumpInfo] {.async.} =
  ## Runs nimble dump, which gets all the entryPoints/projectFiles. 
  if nimbleFile in nimbleDumpCache:
    return nimbleDumpCache[nimbleFile]
  var process: AsyncProcessRef
  try:
    let workDir = parentDir(string(nimbleFile))
    let nimbleDirEnv = getEnv("NIMBLE_DIR", "<not set>")
    let homeEnv = getEnv("HOME", "<not set>")
    let pathEnv = getEnv("PATH", "<not set>")

    debug "getNimbleDumpInfo: environment",
      nimbleFile = $nimbleFile, workDir = workDir,
      NIMBLE_DIR = nimbleDirEnv, HOME = homeEnv, PATH = pathEnv

    process = await startProcess(
      "nimble",
      workingDir = workDir,
      arguments = @["dump"],
      options = {UsePath},
      stderrHandle = AsyncProcess.Pipe,
      stdoutHandle = AsyncProcess.Pipe,
    )
    let info = string.fromBytes(process.stdoutStream.read().await)
    debug "getNimbleDumpInfo: result ", info

    for line in info.splitLines:
      if line.startsWith("srcDir"):
        result.srcDir = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("name"):
        result.name = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("nimDir"):
        result.nimDir = some(line[(1 + line.find '"') ..^ 2])
      if line.startsWith("nimblePath"):
        result.nimblePath = FilePath(line[(1 + line.find '"') ..^ 2])
      if line.startsWith("entryPoints"):
        result.entryPoints =
          line[(1 + line.find '"') ..^ 2].split(',').mapIt(it.strip(chars = {' ', '"'}))

  except CatchableError:
    debug "Failed to get nimble dump info", nimbleFile = $nimbleFile
  finally:
    if process != nil:
      await shutdownChildProcess(process)

proc startNimbleProcess*(
  args: seq[string], workingDir: string
): Future[AsyncProcessRef] {.async.} =
  let nimbleDirEnv = getEnv("NIMBLE_DIR", "<not set>")
  let homeEnv = getEnv("HOME", "<not set>")
  let pathEnv = getEnv("PATH", "<not set>")
  debug "startNimbleProcess environment",
    args = args,
    workingDir = workingDir,
    NIMBLE_DIR = nimbleDirEnv,
    HOME = homeEnv,
    PATH = pathEnv
  await startProcess(
    "nimble",
    arguments = args,
    options = {UsePath},
    workingDir = workingDir,
    stdoutHandle = AsyncProcess.Pipe,
    stderrHandle = AsyncProcess.Pipe,
  )

proc getNimbleTasks*(nimbleDumpCache: Table[FilePath, NimbleDumpInfo]): Future[seq[NimbleTask]] {.async.} =
  # let rootPath: string = ls.capabilities.lspInitializeParams.getRootPath
  # debug "Received tasks ", rootPath = rootPath
  debug "tasks: deleting NIMBLE_DIR before nimble tasks",
    NIMBLE_DIR_before = getEnv("NIMBLE_DIR", "<not set>"),
    HOME = getEnv("HOME", "<not set>")
  delEnv "NIMBLE_DIR"
  
  for nimbleFile, dumpInfo in nimbleDumpCache:
    let nimbleDirectory = parentDir(string(dumpInfo.nimblePath))
    debug "Running `nimble tasks` in directory to get a list of its tasks", dir = nimbleDirectory
    let process = await startNimbleProcess(@["tasks"], workingDir = nimbleDirectory)
    let exitCode = await process.waitForExit(InfiniteDuration)
    if exitCode != 0:
      warn "nimble tasks failed", dir = nimbleDirectory, exitCode = exitCode
      await process.shutdownChildProcess()
      continue
    let output = string.fromBytes(await process.stdoutStream.read())
    var name, desc: string
    for line in output.splitLines:
      if scanf(line, "$+  $*", name, desc):
        #first run of nimble tasks can compile nim and output the result of the compilation
        if name.isWord:
          result.add(NimbleTask(
            name: name.strip(), 
            description: desc.strip(), 
            projectDir: nimbleDirectory
          ))
    await process.shutdownChildProcess()

proc runNimbleTask*(
  params: RunTaskParams
): Future[RunTaskResult] {.async.} =
  let process = await startNimbleProcess(
    params.command, workingDir = params.workingDir
  )
  let res = await process.waitForExit(InfiniteDuration)
  result.command = params.command
  let prefix = "\""
  while not process.stdoutStream.atEof():
    var lines = process.stdoutStream.readLine().await.splitLines
    for line in lines.mitems:
      if line.startsWith(prefix):
        line = line.unescape(prefix)
      if line != "":
        result.output.add(line)

  debug "Ran nimble cmd/task", command = $params.command, output = $result.output
  await process.shutdownChildProcess()


# proc initNimsuggestInstances*(ls: LanguageServer) {.async.} =
#   ## Starts nimsuggest instances.
#   let rootPath = getRootPath(ls.capabilities.lspInitializeParams)

#   debug "initNimsuggestInstances: spawning from rootPath", rootPath = rootPath
#   if rootPath == "":
#     debug "initNimsuggestInstances: rootPath is empty.  Quitting.  This should not happen, as this is the folder the language server is being run from."
#     return

#   let config = ls.configurations.currentConfig

#   # Update pool settings from config (pool was created with defaults in initLanguageServer)
#   ls.pool.maxSlots = config.maxNimsuggestProcesses
#   ls.pool.fileCheckDelay = initDuration(milliseconds = config.fileCheckDelay)

#   # Get all nimble information
#   let foundNimbleFiles = searchForNimbleFiles(string(rootPath))
#   var nimsuggestSet = false
#   # let nimblePath = FilePath("") # Should be rootPath?
#   for i, n in foundNimbleFiles:
#     let nimblePath = FilePath(n)
#     let nimbleDumpInfo: NimbleDumpInfo = await getNimbleDumpInfo(ls.nimbleDumpCache, nimblePath)

#     if nimbleDumpInfo.nimblePath.isSome:
#       let nimblePathToUse = FilePath(nimbleDumpInfo.nimblePath.get())
#       ls.nimbleDumpCache[nimblePathToUse] = nimbleDumpInfo
#     else:
#       ls.nimbleDumpCache[nimblePath] = nimbleDumpInfo

#     if nimsuggestSet == false:
#       # Resolve the nimsuggest binary path and Nim version now that config is available.
#       let (nimsuggestPath, nimVersion) = await getNimSuggestPathAndVersion(nimbleDumpInfo, config)
#       ls.pool.nimsuggestPath = nimsuggestPath
#       ls.pool.nimVersion = nimVersion
#       nimsuggestSet = true
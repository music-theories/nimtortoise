import std/[os, strutils, tables, strscans]
import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils

import forest

import ../protocol/types
import ../utils/process_utils
import ../utils/utils

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

proc getNimbleTasks*(
  nimbleDumpCache: Table[FilePathAbs, NimbleDumpInfo]
): Future[seq[NimbleTask]] {.async.} =
  # let rootPath: string = ls.capabilities.lspInitializeParams.getRootPath
  # debug "Received tasks ", rootPath = rootPath
  debug "tasks: deleting NIMBLE_DIR before nimble tasks",
    NIMBLE_DIR_before = getEnv("NIMBLE_DIR", "<not set>"),
    HOME = getEnv("HOME", "<not set>")
  delEnv "NIMBLE_DIR"
  
  for nimbleFile, dumpInfo in nimbleDumpCache:
    let nimbleDirectory = parentDir(string(nimbleFile))
    debug "Running `nimble tasks` in directory to get a list of its tasks", dir = nimbleDirectory
    let process = await startNimbleProcess(@["tasks"], workingDir = nimbleDirectory)
    let exitCode = await process.waitForExit(InfiniteDuration)
    if exitCode != 0:
      warn "nimble tasks failed", dir = nimbleDirectory, exitCode = exitCode
      await process.shutdownChildProcess()
      continue
    let output = string.fromBytes(await process.stdoutStream.read())
    
    var foundBuild = false
    var foundTest = false
    var name, desc: string
    for line in output.splitLines:
      if scanf(line, "$+  $*", name, desc):
        #first run of nimble tasks can compile nim and output the result of the compilation
        if name.isWord:
          let nameStripped = name.strip()
          result.add(NimbleTask(
            name: nameStripped, 
            description: desc.strip(), 
            projectDir: nimbleDirectory
          ))
          if nameStripped == "build": 
            foundBuild = true
          if nameStripped == "test": 
            foundTest = true
    if foundBuild == false:
      result.add(NimbleTask(
        name: "build", 
        description: "-", 
        projectDir: nimbleDirectory
      ))
    if foundTEst == false:
      result.add(NimbleTask(
        name: "test", 
        description: "-", 
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

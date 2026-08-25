import std/[os, strutils, tables, options]
import chronos

import chronicles

import forest

import ../protocol/types
import ../utils/utils

import ../nimsuggest/[nimsuggest_types, suggestapi_types]


proc commonPrefixLen(a, b: string): int =
  let aParts = a.split(DirSep)
  let bParts = b.split(DirSep)
  for i in 0 ..< min(aParts.len, bParts.len):
    if aParts[i] == bParts[i]: inc result
    else: break

proc getNimsuggestSpawnInfo*(
  fileOpened: FilePathAbs, 
  rootPath: DirPathAbs, 
  dependencies: Forest
): NimsuggestSpawnInfo = 
  ## Gets spawning info.
  ## The working directory should be the directory to spawn the nimsuggest instance from, and should be the closest file with a .nimble file.
  result = NimsuggestSpawnInfo(
    entryPoint: FilePathAbs(""),
    workingDir: DirPathAbs(""),
    nimbleFile: none(FilePathAbs),
    paths: @[]
  )

  # Step 1: Walk up from fileOpened to find a .nimble file or reach rootPath.
  var nimbleFile = none(FilePathAbs)
  var dir = parentDir(string(fileOpened))
  while dir.len > 0:
    for candidate in walkFiles(dir / "*.nimble"):
      nimbleFile = some(FilePathAbs(candidate))
      break
    if nimbleFile.isSome:
      break
    if dir == string(rootPath):
      break
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent

  # Step 2: Cross-reference `nimble` field of `dependencies` to find entry points.
  # workingDir defaults to parentDir(fileOpened); updated to nimble dir if found.
  var workingDir = DirPathAbs(parentDir(string(fileOpened)))
  var entryPoints: seq[FilePathAbs] = @[]

  if nimbleFile.isSome:
    let nf = nimbleFile.get()
    result.nimbleFile = nimbleFile
    workingDir = DirPathAbs(parentDir(string(nf)))
    if nf in dependencies.nimble.dump:
      let dumpInfo = dependencies.nimble.dump[nf]
      let nimbleDir = parentDir(string(nf))
      for ep in dumpInfo.entryPoints:
        let abs = FilePathAbs((nimbleDir / string(ep)).normalizedPath)
        if fileExists(string(abs)):
          entryPoints.add(abs)

  result.workingDir = workingDir

  # If no entry points found, treat fileOpened as its own entry point.
  if entryPoints.len == 0:
    result.entryPoint = fileOpened
    result.paths = dependencies.paths.getOrDefault(fileOpened, @[])
    return

  # Step 3: Find the entry point closest to fileOpened that can reach it.
  # "Closest" = longest common path prefix (most directory components shared).
  # Prefer entry points that transitively import fileOpened; fall back to
  # proximity alone for orphan files not reachable from any entry point.

  var bestEntryPoint = FilePathAbs("")
  var bestScore = -1
  var anyReachable = false

  for ep in entryPoints:
    if isDependency(dependencies.trees, ep, fileOpened) or ep == fileOpened:
      anyReachable = true
      let score = commonPrefixLen(string(ep), string(fileOpened))
      if score > bestScore:
        bestScore = score
        bestEntryPoint = ep

  # Step 4: A reachable entry point was found — use the best (closest) one.
  if anyReachable:
    result.entryPoint = bestEntryPoint
    result.paths = dependencies.paths.getOrDefault(bestEntryPoint, @[])

  else:
    # Step 5: No entry point can reach fileOpened (orphan) — it becomes its own entry point.
    result.entryPoint = fileOpened
    result.paths = @[]

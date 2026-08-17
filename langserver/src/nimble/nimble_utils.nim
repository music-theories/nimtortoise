import std/[os, sequtils, strutils, tables, options, strscans, sugar]
import chronos
import chronos/asyncproc
import chronicles
import regex
import stew/byteutils

import forest

import ../protocol/types
import ../utils/utils
import ../configurations/configurations
import ../nimsuggest/[nimsuggest_types, suggestapi_types]

import ./[nimble_types]

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
    if nf in dependencies.nimble:
      let dumpInfo = dependencies.nimble[nf]
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

  # Step 4: No entry point can reach fileOpened (orphan) - it becomes its own entry point.  No paths found in this case.  TODO - maybe do a nim dump to get paths?
  if anyReachable:
    result.entryPoint = fileOpened
    result.paths = @[]

  else:
    # Step 5: Get lib search paths for this entry point from dependencies.paths.
    result.entryPoint = bestEntryPoint
    result.paths = dependencies.paths.getOrDefault(bestEntryPoint, @[])

# proc findNimblePaths*(
#   fromFile: string, rootFolder: string
# ): seq[string] =
#   ## Walk up from fromFile's directory looking for nimble.paths.
#   ## Returns the flags it contains (--noNimblePath and --path:... entries)
#   ## with any surrounding quotes stripped, ready to pass directly to nimsuggest.
#   var dir = fromFile.parentDir
#   while dir.len > 0:
#     let pathsFile = dir / "nimble.paths"
#     if pathsFile.fileExists:
#       debug "Found nimble.paths for nimsuggest", path = pathsFile
#       for line in pathsFile.lines:
#         let trimmed = line.strip()
#         if trimmed.len == 0:
#           continue
#         if trimmed.startsWith("--path:"):
#           # nimble.paths wraps paths in quotes: --path:"/foo/bar"
#           # Strip them so the arg is passed cleanly to nimsuggest.
#           let val = trimmed[7 .. ^1]
#           if val.len >= 2 and val[0] == '"' and val[^1] == '"':
#             result.add("--path:" & val[1 .. ^2])
#           else:
#             result.add(trimmed)
#         else:
#           result.add(trimmed)
#       return
#     if dir == rootFolder:
#       break
#     let parent = dir.parentDir
#     if parent == dir:
#       break
#     dir = parent
#   warn "No nimble.paths file found.  This may cause problems.  Consider running `nimble setup` before continuing."

# echo findNimblePaths("langserver/src/nimble_nimble_utils.nim", "langserver")

# # === PROJECT MAPPING ===
# var compiledRegexCache {.threadvar.}: Table[string, Regex2]

# proc getCompiledRegex(pattern: string): Regex2 =
#   ## Returns a cached compiled Regex2 for pattern, compiling it on first use.
#   ## Chronos is single-threaded cooperative, so no locking is needed.
#   if pattern notin compiledRegexCache:
#     compiledRegexCache[pattern] = re2(pattern)
#   compiledRegexCache[pattern]

# proc clearCompiledRegexCache*() =
#   ## Invalidate the regex cache. Call after workspace configuration changes so
#   ## that stale projectMapping patterns are not reused across config updates.
#   compiledRegexCache.clear()

##[
Path: a filesystem path string, e.g.
/Users/dp/projects/monorepo/pkga/src/pkga.nim
URI: an LSP file URI, e.g.
file:///Users/dp/projects/monorepo/pkga/src/pkga.nim
The URI has the file:// scheme prefix. uriToPath strips it; pathToUri adds it.
]##

# proc getEntryPointFromProjectMapping*(
#   filePath: FilePathAbs,
#   rootPath: DirPathAbs,
#   projectMapping: seq[NlsNimsuggestConfig]
# ): FilePathAbs =
#   ## ProjectMapping regex lookup only. No slot creation, no LRU fallback.
#   ## Returns FilePathAbs("") if no mapping matches.
#   let pathAsString = string(filePath)
#   let rootPathAsString = string(rootPath)
#   let pathRelativeToRoot = tryRelativeTo(pathAsString, rootPathAsString)
#   echo "pathRelativeToRoot ", pathRelativeToRoot
#   for mapping in projectMapping:
#     var m: RegexMatch2
#     let compiledRegex = re2(mapping.fileRegex)
#     echo "pathAsString ", pathAsString
#     if find(pathAsString, compiledRegex, m):
#       echo "m: ", $m
#       echo "mapping: ", $mapping.projectFile
#       if mapping.projectFile == "":
#         echo "empty projectFile"
#         return filePath  # regex matched but no projectFile — file is its own project
#       elif isAbsolute(mapping.projectFile):
#         echo "isAbsolute: ", isAbsolute(mapping.projectFile)
#         return FilePathAbs(mapping.projectFile)
#       else:
#         echo "other: "
#         return rootPath / FilePathRel(mapping.projectFile)
#   echo "OH NO! "
#   return FilePathAbs("")

# let testProjectMapping: seq[NlsNimsuggestConfig] = @[
#   NlsNimsuggestConfig(
#     projectFile: "langserver/src/nimtortoise.nim",
#     fileRegex: "langserver/src/.*\\.nim"
#   ),
#   NlsNimsuggestConfig(
#     projectFile: "langserver/tests/all.nim",
#     fileRegex: "langserver/tests/.*\\.nim"
#   )
# ]

# echo "ENTRY POINT ", getEntryPointFromProjectMapping(
#   FilePathAbs("langserver/"),
#   DirPathAbs(""),
#   testProjectMapping
# )
# let compiledRegex = re2("langserver/src/.*\\.nim")  
# # echo "pathAsString ", pathAsString
# echo regex.match("langserver/src/nimble/nimble_utils.nim", compiledRegex)

# echo regex.match("langserver/tests/textensions.nim", compiledRegex)

# echo regex.match("langserver/src/nimble_tortoise.nim", compiledRegex)

# echo regex.match("vscode_extension/src/nimble/nimble_utils.nim", compiledRegex)

# {
#   "projectFile": "vscode_extension/src/vscode_nim_tortoise.nim",
#   "fileRegex": "vscode_extension/src/.*\\.nim"
# },




# === ENTRY POINTS ===
# proc getNimbleEntryPoints*(
#   dumpInfo: NimbleDumpInfo, nimbleProjectPath: string
# ): seq[string] =
#   if dumpInfo.entryPoints.len > 0:
#     result = dumpInfo.entryPoints.mapIt(nimbleProjectPath / it)
#   else:
#     #Nimble doesnt include the entry points, returning the nimble project file as the entry point
#     let sourceDir = nimbleProjectPath / dumpInfo.srcDir
#     result = @[sourceDir / (dumpInfo.name & ".nim")]
#   result = result.filterIt(it.fileExists)

# proc getEntryPoints(
#   ls: LanguageServer, rootPath: FilePath
# ): Future[seq[FilePath]] {.async.}  = 
#   # Discover entry points via nimble dump.
#   # Search rootPath first, then one level of subdirectories (handles workspaces
#   # where the nimble project root is a subfolder of the opened workspace).
#   let nimbleFiles = searchForNimbleFiles(rootPath)

#   if nimbleFiles.len > 0:
#     debug "Found nimble files ", nimbleFiles = nimbleFiles
#     let nimbleFile = FilePath(nimbleFiles[0]) # Why only the first file?
#     # Use the nimble file's parent directory as the project root, not the
#     # workspace root — they may differ when the project is in a subfolder.
#     debug "Starting nimble dump for", nimbleFile = $nimbleFile
#     let nimbleDumpInfo: NimbleDumpInfo = await getNimbleDumpInfo(ls.nimbleDumpCache, nimbleFile)

#     if nimbleDumpInfo.nimblePath.isSome:
#       let nimblePathToUse = FilePath(nimbleDumpInfo.nimblePath.get())
#       ls.nimbleDumpCache[nimblePathToUse] = nimbleDumpInfo
#     else:
#       ls.nimbleDumpCache[nimbleFile] = nimbleDumpInfo
    
#     let nimbleProjectRoot = parentDir(string(nimbleFile))
#     let entryPoints = nimbleDumpInfo.getNimbleEntryPoints(nimbleProjectRoot).mapIt(FilePath(it))

#     debug "Finished nimble dump", nimbleFile = $nimbleFile
#     debug "Found the following entryPoints", entryPoints = $entryPoints
#     return entryPoints
#   else:
#     debug "Found no nimble files."
#     return @[]


# var nimbleDirs: seq[string]
# if walkFiles(rootPath / "*.nimble").toSeq.len > 0:
#   nimbleDirs.add(rootPath)
# else:
#   for entry in walkDir(rootPath):
#     if entry.kind == pcDir:
#       if walkFiles(entry.path / "*.nimble").toSeq.len > 0:
#         nimbleDirs.add(entry.path)

# # Find nimble directories: check the workspace root first, then one level deep.
# var nimbleDirs: seq[string]
# if walkFiles(rootPath / "*.nimble").toSeq.len > 0:
#   nimbleDirs.add(rootPath)
# else:
#   for entry in walkDir(rootPath):
#     if entry.kind == pcDir:
#       if walkFiles(entry.path / "*.nimble").toSeq.len > 0:
#         nimbleDirs.add(entry.path)

# if nimbleDirs.len == 0:
#   warn "No .nimble files found in workspace root or immediate subdirectories",
#     rootPath = rootPath
#   return @[]

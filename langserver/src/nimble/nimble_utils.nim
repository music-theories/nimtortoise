import std/[os, sequtils, strutils, tables, options, strscans, sugar]
import chronos
import chronos/asyncproc
import chronicles
import regex
import stew/byteutils

import ../protocol/types
import ../utils/process_utils
import ../utils/utils
import ../configurations/configurations
import ./[nimble_types]


## BIG NOTE: You need to ensure that, on consolidation, you take into account the parameter mapping.
## You also need to work out exactly what this workingDir thing is and where it is called.
## This probably needs to work PER SLOT - as each slot as a workingDir on `NimsuggestSlot`.
proc getWorkingDir*(rootPath: FilePath, path: FilePath, config: NlsConfig): string =
  ## Gets working directory.
  # let rootPath = uriToPath(rootUri)
  # TODO/NOTE: I DO NOT UNDERSTAND WHAT THE WORKING DIR IS OR HOW IT SHOULD BE USED !!!!!!
  let rootPathAsString = string(rootPath)
  let pathRelativeToRoot = string(path).tryRelativeTo(rootPathAsString)
  let mapping = config.workingDirectoryMapping
  result = parentDir(string(path)) # This won't work - will only give back the directory the binary is running in.
  
  for m in mapping:
    if pathRelativeToRoot.isSome() and m.projectFile == pathRelativeToRoot.get():
      result = rootPathAsString / m.directory
      break


##[
- GET ENTRY POINT
- First check project mapping
  - If there is a relevant project mapping, use that.  
- If not, check nimble entry points by walking the directory structure from the seletced file up to the rootPath, looking for a suitable nimble file - or do we need to iterate over the nimble dump cache?
]##


# === FIND NIMBLE FILES ===
proc searchForNimbleFiles*(rootPath: FilePath): seq[FilePath] = 
  # Search rootPath first, then one level of subdirectories (handles workspaces
  # where the nimble project root is a subfolder of the opened workspace).
  var output: seq[string] = @[]
  let rootPathAsString = string(rootPath)
  output = walkFiles(rootPathAsString / "*.nimble").toSeq()
  if output.len == 0:
    for subdir in walkDirs(rootPathAsString / "*"):
      output.add(walkFiles(subdir / "*.nimble").toSeq())
  return map(output, x => toFilePath(x))

# === PROJECT MAPPING ===
var compiledRegexCache {.threadvar.}: Table[string, Regex2]

proc getCompiledRegex(pattern: string): Regex2 =
  ## Returns a cached compiled Regex2 for pattern, compiling it on first use.
  ## Chronos is single-threaded cooperative, so no locking is needed.
  if pattern notin compiledRegexCache:
    compiledRegexCache[pattern] = re2(pattern)
  compiledRegexCache[pattern]

proc clearCompiledRegexCache*() =
  ## Invalidate the regex cache. Call after workspace configuration changes so
  ## that stale projectMapping patterns are not reused across config updates.
  compiledRegexCache.clear()

proc getEntryPointFromProjectMapping*(
  rootPath: FilePath, uri: FileUri, config: NlsConfig
): FilePath =
  ## ProjectMapping regex lookup only. No slot creation, no LRU fallback.
  ## Returns FilePath("") if no mapping matches.
  let path = uriToPath(uri)
  let pathAsString = string(path)
  let rootPathAsString = string(rootPath)
  let pathRelativeToRoot = tryRelativeTo(pathAsString, rootPathAsString)
  for mapping in config.projectMapping:
    var m: RegexMatch2
    if find(pathAsString, getCompiledRegex(mapping.fileRegex), m):
      if mapping.projectFile == "":
        return path  # regex matched but no projectFile — file is its own project
      elif isAbsolute(mapping.projectFile):
        return FilePath(mapping.projectFile)
      else: 
        return FilePath(rootPathAsString / mapping.projectFile)
  return FilePath("")



# === ENTRY POINTS ===
proc getNimbleEntryPoints*(
  dumpInfo: NimbleDumpInfo, nimbleProjectPath: string
): seq[string] =
  if dumpInfo.entryPoints.len > 0:
    result = dumpInfo.entryPoints.mapIt(nimbleProjectPath / it)
  else:
    #Nimble doesnt include the entry points, returning the nimble project file as the entry point
    let sourceDir = nimbleProjectPath / dumpInfo.srcDir
    result = @[sourceDir / (dumpInfo.name & ".nim")]
  result = result.filterIt(it.fileExists)

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

proc findNimblePaths*(fromFile: string): seq[string] =
  ## Walk up from fromFile's directory looking for nimble.paths.
  ## Returns the flags it contains (--noNimblePath and --path:... entries)
  ## with any surrounding quotes stripped, ready to pass directly to nimsuggest.
  var dir = fromFile.parentDir
  while dir.len > 0:
    let pathsFile = dir / "nimble.paths"
    if pathsFile.fileExists:
      debug "Found nimble.paths for nimsuggest", path = pathsFile
      for line in pathsFile.lines:
        let trimmed = line.strip()
        if trimmed.len == 0:
          continue
        if trimmed.startsWith("--path:"):
          # nimble.paths wraps paths in quotes: --path:"/foo/bar"
          # Strip them so the arg is passed cleanly to nimsuggest.
          let val = trimmed[7 .. ^1]
          if val.len >= 2 and val[0] == '"' and val[^1] == '"':
            result.add("--path:" & val[1 .. ^2])
          else:
            result.add(trimmed)
        else:
          result.add(trimmed)
      return
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent

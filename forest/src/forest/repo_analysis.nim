import std/[os, sequtils, sets, options, strutils]
import chronos
import chronicles
import ./[forest_types, nimble_dump, nim_dump, dependency_tree]
import ../resources/resources

# proc filterToRepoRoot(paths: seq[DirPathAbs], repoRoot: DirPathAbs): seq[DirPathAbs] =
#   ## Returns only paths that are inside repoRoot.
#   let root = string(repoRoot).normalizedPath
#   for p in paths:
#     if string(p).normalizedPath.startsWith(root):
#       result.add(p)

# proc getIntraRepoPaths(entryPoint: FilePathAbs, repoRoot: DirPathAbs): seq[DirPathAbs] =
#   ## Runs nim dump on entryPoint and returns libPaths filtered to repoRoot.
#   let info = getNimDumpInfo(entryPoint)
#   if info.isNone:
#     warn "nim dump failed, skipping search paths", entryPoint = $entryPoint
#     return @[]
#   filterToRepoRoot(info.get.libPaths, repoRoot)

# proc buildRepoDependencyGraph*(repoRoot: DirPathAbs): DependencyGraph =
#   ## Full pipeline:
#   ## 1. Find all .nimble files under repoRoot
#   ## 2. nimble dump each → collect entryPoints + testEntryPoint
#   ## 3. Resolve entry point paths relative to their nimble file's directory
#   ## 4. nim dump the first valid entry point per package → collect intra-repo search paths
#   ## 5. Build a single combined dependency graph across all entry points
#   let root = DirPathAbs(string(repoRoot).absolutePath.normalizedPath)
#   let nimbleFiles = searchForNimbleFiles(root)

#   if nimbleFiles.len == 0:
#     warn "No .nimble files found", repoRoot = $root
#     return DependencyGraph(root: root)

#   var allEntryPoints: seq[FilePathAbs]
#   var allSearchPaths: HashSet[DirPathAbs]

#   for nimbleFile in nimbleFiles:
#     let nimbleDir = parentDir(nimbleFile)
#     let dumpInfo = waitFor getNimbleDumpInfo(nimbleFile)
#     if dumpInfo.isNone:
#       warn "nimble dump failed, skipping", nimbleFile = $nimbleFile
#       continue

#     let info = dumpInfo.get

#     # Collect all entry points for this package (resolved to absolute paths).
#     var packageEntries: seq[FilePathAbs]
#     for ep in info.entryPoints:
#       let abs = FilePathAbs((string(nimbleDir) / string(ep)).absolutePath.normalizedPath)
#       if fileExists(string(abs)):
#         packageEntries.add(abs)
#       else:
#         warn "entry point not found, skipping", path = $abs

#     if string(info.testEntryPoint).len > 0:
#       let abs = FilePathAbs((string(nimbleDir) / string(info.testEntryPoint)).absolutePath.normalizedPath)
#       if fileExists(string(abs)):
#         packageEntries.add(abs)

#     allEntryPoints.add(packageEntries)

#     # Run nim dump on the first valid entry point to get intra-repo search paths.
#     if packageEntries.len > 0:
#       for p in getIntraRepoPaths(packageEntries[0], root):
#         allSearchPaths.incl(p)

#   if allEntryPoints.len == 0:
#     warn "No valid entry points found across all packages", repoRoot = $root
#     return DependencyGraph(root: root)

#   debug "building dependency graph",
#     entryPoints = allEntryPoints.len,
#     searchPaths = allSearchPaths.len

#   initDependencyGraph(allEntryPoints, allSearchPaths.toSeq, root)


# when isMainModule:
#   let repoRoot =
#     if paramCount() >= 1: DirPathAbs(paramStr(1))
#     else: DirPathAbs(currentSourcePath().parentDir / ".." / ".." / ".." / "..")
#   let graph = buildRepoDependencyGraph(repoRoot)
#   echo formatInJson(graph)

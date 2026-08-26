import std/[os, tables, strutils]
import chronos

import ../resources/resources

import ./[
  dependency_tree,
  nimble_dump, nim_dump,
  forest_utils, forest_types,
]

proc initForest*(
  rootPath: DirPathAbs
): Future[Forest] {.async.} = 

  result = Forest(
    root: rootPath,
    nim:    NimInfo(version: "", nimExe: FilePathAbs("")),
    nimble: NimbleInfo(
      dump: initTable[FilePathAbs, NimbleDumpInfo](),
      entryPoints: @[]
    ),
    paths: initTable[FilePathAbs, seq[DirPathAbs]](),
    trees: initTable[FilePathAbs, seq[FilePathAbs]]()
  )

  if dirExists(string(rootPath)):
    let nimbleInfo = initNimbleInfo(rootPath)
    let nimDumpInfo = getNimDumpInfoForEntryPoints(
      nimbleInfo.entryPoints, rootPath
    )
    result.nimble = nimbleInfo

    var nimInfoSet = false
    for entryPoint, nimDump in nimDumpInfo:
      if nimInfoSet == false:
        result.nim = NimInfo(
          version: nimDump.version,
          nimExe:  nimDump.nimExe
        )
        nimInfoSet = true
      for path in nimDump.libPaths:
        if path.isInside(rootPath):
          if entryPoint notin result.paths:
            result.paths[entryPoint] = @[]
          if path notin result.paths[entryPoint]:
            result.paths[entryPoint].add(path)

    # Derive search paths from all local nimble packages' src directories.
    # This lets resolveImport find bare package-name imports (e.g. `import foo`)
    # without requiring nim dump to include nimble paths.
    var searchPaths: seq[DirPathAbs]
    for nimbleFile, dump in nimbleInfo.dump:
      let srcPath = DirPathAbs(
        (parentDir(string(nimbleFile)) / string(dump.srcDir)).normalizedPath
      )
      if dirExists(string(srcPath)) and srcPath notin searchPaths:
        searchPaths.add(srcPath)

    var dependencyGraph = initDependencyGraph(
      nimbleInfo.entryPoints, rootPath, searchPaths
    )
    result.trees = dependencyGraph.graph

proc initForest*(
  rootPathString: string
): Future[Forest] {.async.} = 
  let rootPath = DirPathAbs(rootPathString.absolutePath().normalizedPath())
  return await initForest(rootPath)

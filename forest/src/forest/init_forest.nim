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
    nimble: initTable[FilePathAbs, NimbleDumpInfo](),
    paths: initTable[FilePathAbs, seq[DirPathAbs]](),
    trees: initTable[FilePathAbs, seq[FilePathAbs]]()
  )

  if dirExists(string(rootPath)):
    let nimbleInfo = initNimbleInfo(rootPath)
    let nimDumpInfo = getNimDumpInfoForEntryPoints(
      nimbleInfo.entryPoints, rootPath
    )
    var dependencyGraph = initDependencyGraph(
      nimbleInfo.entryPoints, rootPath
    )
    result.nimble = nimbleInfo.dump

    var nimInfoSet = false
    for entryPoint, nimDump in nimDumpInfo:
      if nimInfoSet == false:
        result.nim = NimInfo(
          version: nimDump.version,
          nimExe:  nimDump.nimExe
        )
        nimInfoSet = true
      
      let source = readFile(string(entryPoint))
      for importName in extractImports(source):
        let modulePath = importName.replace('.', DirSep)
        for path in nimDump.libPaths:
          if path.isInside(rootPath):
            if entryPoint notin result.paths:
              result.paths[entryPoint] = @[]
            if path notin result.paths[entryPoint]:
              result.paths[entryPoint].add(path)

            let candidate = FilePathAbs(
              (string(path) / modulePath & ".nim").normalizedPath
            )
            if fileExists(string(candidate)):
              if entryPoint notin dependencyGraph.graph:
                dependencyGraph.graph[entryPoint] = @[]
              if candidate notin dependencyGraph.graph[entryPoint]:
                dependencyGraph.graph[entryPoint].add(candidate)

    result.trees = dependencyGraph.graph

proc initForest*(
  rootPathString: string
): Future[Forest] {.async.} = 
  let rootPath = DirPathAbs(rootPathString.absolutePath().normalizedPath())
  return await initForest(rootPath)

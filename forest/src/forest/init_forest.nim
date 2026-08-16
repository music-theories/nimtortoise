import std/[os, strformat, options, tables, strutils]
import chronos

import ../resources/resources

import ./[
  dependency_tree,
  nimble_dump, nim_dump,
  forest_utils, forest_types,
]

proc initForest*(
  rootPathString: string
): Future[Forest] {.async.} = 
  let rootPath = DirPathAbs(rootPathString.absolutePath().normalizedPath())

  result = Forest(
    root: rootPath,
    nimble: initTable[FilePathAbs, NimbleDumpInfo](),
    paths: initTable[FilePathAbs, seq[DirPathAbs]](),
    trees: initTable[FilePathAbs, seq[FilePathAbs]]()
  )

  if dirExists(rootPathString):
    let nimbleInfo = initNimbleInfo(rootPath)
    let nimDumpInfo = getNimDumpInfoForEntryPoints(
      nimbleInfo.entryPoints, rootPath
    )
    var dependencyGraph = initDependencyGraph(
      nimbleInfo.entryPoints, rootPath
    )
    result.nimble = nimbleInfo.dump
    result.trees = dependencyGraph.graph

    for entryPoint, nimDump in nimDumpInfo:
      let source = readFile(string(entryPoint))
      for importName in extractImports(source):
        let modulePath = importName.replace('.', DirSep)
        for path in nimDump.libPaths:
          if path.isInside(rootPath):
            if entryPoint in result.paths:
              result.paths[entryPoint].add(path)
            else: 
              result.paths[entryPoint] = @[path]

            let candidate = FilePathAbs(
              (string(path) / modulePath & ".nim").normalizedPath
            )
            if fileExists(string(candidate)):
              if entryPoint notin dependencyGraph.graph:
                dependencyGraph.graph[entryPoint] = @[]
              if candidate notin dependencyGraph.graph[entryPoint]:
                dependencyGraph.graph[entryPoint].add(candidate)

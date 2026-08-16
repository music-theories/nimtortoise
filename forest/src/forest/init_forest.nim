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
): Future[Option[Forest]] {.async.} = 
  let rootPath = DirPathAbs(rootPathString.absolutePath().normalizedPath())

  if dirExists(rootPathString):
    let nimbleInfo = initNimbleInfo(rootPath)
    let nimDumpInfo = getNimDumpInfoForEntryPoints(
      nimbleInfo.entryPoints, rootPath
    )
    var dependencyGraph = initDependencyGraph(
      nimbleInfo.entryPoints, rootPath
    )
    for entryPoint, nimDump in nimDumpInfo:
      let source = readFile(string(entryPoint))
      for importName in extractImports(source):
        let modulePath = importName.replace('.', DirSep)
        for path in nimDump.libPaths:
          if path.isInside(rootPath):
            let candidate = FilePathAbs(
              (string(path) / modulePath & ".nim").normalizedPath
            )
            if fileExists(string(candidate)):
              if entryPoint notin dependencyGraph.graph:
                dependencyGraph.graph[entryPoint] = @[]
              if candidate notin dependencyGraph.graph[entryPoint]:
                dependencyGraph.graph[entryPoint].add(candidate)


    return some(Forest(
      nimble: nimbleInfo,
      nim: nimDumpInfo,
      dependencies: dependencyGraph
    ))

  else:
    quit(fmt"Could not generate dependency graph, this folder does not exist: {rootPathString}")
    return none(Forest)


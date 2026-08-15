import std/[os]
import ./nimforest/dependency_tree

when isMainModule:
  if paramCount() != 1:
    quit("Usage: nimdeps <path/to/file.nim>", 1)

  var dependencyGraph = initDependencyGraph(paramStr(1))
  echo formatInJson(dependencyGraph)

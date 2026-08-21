import std/[os, strformat, monotimes, json, jsonutils]
import chronos
import ./forest/[
  init_forest,
  forest_utils, forest_types, 
  dependency_tree, dependency_tree_utils, 
  bfs
]
export 
  init_forest,
  forest_utils, forest_types,
  dependency_tree, dependency_tree_utils,
  bfs

import ./resources/resources
export resources

when isMainModule:
  var outputJson = false
  var rootPath = ""

  for i in 1..paramCount():
    case paramStr(i)
    of "--json": 
      outputJson = true
    else:        
      rootPath = paramStr(i)

  if rootPath == "":
    quit("Usage: forest [--json] <path/to/dir>", 1)

  if dirExists(rootPath):
    let t0 = getMonoTime()
    let outputForest = waitFor initForest(rootPath)
    let totalTime = fmt"initForest took {getMonoTime() - t0}"
    if outputJson:  
      echo outputForest.toJson().pretty()
    else:
      echo debugStr(outputForest)
      echo totalTime
  else:
    quit(fmt"Could not generate dependency graph, this folder does not exist: {rootPath}")

import std/[os, strformat, options, monotimes]
import chronos
import ./forest/[
  init_forest,
  forest_utils, forest_types, 
  dependency_tree, dependency_tree_utils, 
]
export 
  init_forest,
  forest_utils, forest_types,
  dependency_tree, dependency_tree_utils

import ./resources/resources
export resources


when isMainModule:
  if paramCount() != 1:
    quit("Usage: forest <path/to/file.nim>", 1)
    
  let rootPath = paramStr(1)
  if dirExists(rootPath):
    let t0 = getMonoTime()
    let output = waitFor initForest(rootPath)
    let totalTime = fmt"initForest took {getMonoTime() - t0}"
    if output.isSome():
      let success = output.get()
      echo debugStr(success)
      echo totalTime
    else:
      echo "FOREST FAILURE"
  else:
    quit(fmt"Could not generate dependency graph, this folder does not exist: {rootPath}")

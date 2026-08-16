import std/[os, strformat, options, monotimes]
import chronos
import ./forest/[
  init_forest,
  forest_utils, forest_types, 
  dependency_tree, dependency_tree_utils, 
  repo_analysis
]
import ./resources/resources

when isMainModule:
  # let rootPath = "/Users/dp/Desktop/software_libraries/nim_tortoise"
  let rootPath = "/Users/dp/Desktop/funis/funis"
  if dirExists(rootPath):
    let t0 = getMonoTime()
    let output = waitFor initForest(rootPath)
    let totalTime = fmt"initForest took {getMonoTime() - t0}"
    if output.isSome():
      let success = output.get()
      echo debugStr(success)
      # let check = success.dependencies.graph.checkDependency(
      #   FilePathAbs(rootPath / "langserver/src/nimsuggest/nimsuggest.nim")
      #     .isADependencyOf(FilePathAbs(rootPath / "langserver/src/nimtortoise.nim"))
      # )
      # echo check
      echo totalTime
      
    else:
      echo "FAILURE"
    # let repoGraph: DependencyGraph = buildRepoDependencyGraph(root)


    # let check2 = repoGraph.graph.checkDependency(
    #   FilePathAbs(rootPath / "langserver/src/nimtortoise.nim")
    #     .isADependencyOf(FilePathAbs(rootPath / "langserver/src/nimsuggest/nimsuggest.nim"))
    # )
    # echo check2
  else:
    quit(fmt"Could not generate dependency graph, this folder does not exist: {rootPath}")

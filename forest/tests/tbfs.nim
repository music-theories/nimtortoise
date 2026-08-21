import std/[monotimes, json, jsonutils, strformat]
import chronos
import forest

let rootPath = DirPathAbs("/Users/dp/Desktop/funis/funis/controller")

let t0 = getMonoTime()
let forestDependencies = waitFor initForest(rootPath)
let totalTime = fmt"initForest took {getMonoTime() - t0}"
# if outputJson:  
echo forestDependencies.toJson().pretty()
# else:
# echo debugStr(forestDependencies)
echo totalTime

# let dg = initDependencyGraph(@[entryFile], DirPathAbs(""))


let intermediaryPath = findIntermediatePathBfs(
  forestDependencies.trees, 
  fromFile = FilePathAbs("/Users/dp/Desktop/funis/funis/controller/user_interfaces_shared/src/user_interfaces_shared.nim"),
  toFile = FilePathAbs("/Users/dp/Desktop/funis/funis/controller/user_interfaces_shared/src/user_interfaces_shared/components/melodies/melody_layout_types.nim"),
)

echo "path ", intermediaryPath

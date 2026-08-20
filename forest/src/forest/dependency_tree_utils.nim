import std/[os, tables, sets, algorithm, sequtils, deques]
import ./[forest_types]
import ../resources/resources

proc isDependency*(
  graph:          Table[FilePathAbs, seq[FilePathAbs]],
  rootFile:       FilePathAbs,
  dependencyFile: FilePathAbs
): bool =
  ## Returns true if dependencyFile is a direct or transitive dependency
  ## of rootFile (i.e. rootFile imports it, directly or indirectly).
  var visited: HashSet[FilePathAbs]
  var stack = @[rootFile]
  while stack.len > 0:
    let current = stack.pop()
    if current == dependencyFile:
      return true
    if current in visited:
      continue
    visited.incl(current)
    for dep in graph.getOrDefault(current, @[]):
      stack.add(dep)

proc isDependent*(
  graph:         Table[FilePathAbs, seq[FilePathAbs]],
  rootFile:      FilePathAbs,
  dependentFile: FilePathAbs
): bool =
  ## Returns true if rootFile is a direct or transitive dependency of
  ## dependentFile (i.e. dependentFile imports rootFile, directly or indirectly).
  return isDependency(graph, dependentFile, rootFile)

func isADependencyOf*(
  dependentFile, rootFile: FilePathAbs
): Dependency =
  Dependency(
    rootFile:      rootFile,
    dependentFile: dependentFile
  )

func isADependentOf*(
  rootFile, dependentFile: FilePathAbs
): Dependency =
  Dependency(
    rootFile:      rootFile,
    dependentFile: dependentFile
  )

proc checkDependency*(
  graph:      Table[FilePathAbs, seq[FilePathAbs]],
  dependency: Dependency
): bool =
  if not fileExists(string(dependency.rootFile)):
    echo "ROOT FILE DOES NOT EXIST ", string(dependency.rootFile)
    return false

  if not fileExists(string(dependency.dependentFile)):
    echo "DEPENDENT FILE DOES NOT EXIST ", string(dependency.dependentFile)
    return false

  return graph.isDependency(
    dependency.rootFile,
    dependency.dependentFile
  )

proc findIntermediatePath*(
  graph:    Table[FilePathAbs, seq[FilePathAbs]],
  fromFile: FilePathAbs,
  toFile:   FilePathAbs
): seq[FilePathAbs] =
  ## Returns intermediate files on a path fromFile → ... → toFile,
  ## following import edges, excluding both endpoints.
  ## Result is in execution order: closest to toFile first,
  ## so callers can refresh the cache layer-by-layer toward fromFile.
  ## Returns empty seq if directly connected or no path exists.
  var visited: HashSet[FilePathAbs]
  var stack: seq[seq[FilePathAbs]]
  stack.add(@[fromFile])
  while stack.len > 0:
    let currentPath = stack.pop()
    let current = currentPath[^1]
    if current == toFile:
      if currentPath.len > 2:
        result = currentPath[1..^2]
        result.reverse()
      return
    if current in visited:
      continue
    visited.incl(current)
    for dep in graph.getOrDefault(current, @[]):
      if dep notin visited:
        stack.add(currentPath & dep)

# func orderAndDeduplicateDependencyPaths*[T](
#   dependencyPaths: seq[seq[T]]
# ): seq[T] =
#   var output: seq[T] = @[]
#   for i in 0..100:
#     var arraysLeft = 0
#     for path in dependencyPaths:
#       if i < path.len:
#         output.add(path[i])
#         arraysLeft += 1
#     if arraysLeft == 0:
#       break
#   debugEcho output
#   return output.deduplicate()

# echo orderAndDeduplicateDependencyPaths[int](
#   @[
#     @[0, 1, 2, 3, 4, 5],
#     @[2, 6],
#     @[3, 4, 5, 7],
#     @[0, 1]
#   ]
# )



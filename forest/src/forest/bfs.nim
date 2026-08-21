import std/[tables, sets, algorithm, sequtils, deques]
import ./[forest_types, dependency_tree_utils]
import ../resources/resources

proc findIntermediatePathBfs*(
  graph:    Table[FilePathAbs, seq[FilePathAbs]],
  fromFile: FilePathAbs,
  toFile:   FilePathAbs
): seq[FilePathAbs] =
  ## Returns intermediate files on the SHORTEST path fromFile → ... → toFile,
  ## following import edges, excluding both endpoints.
  ## Result is in execution order: closest to toFile first,
  ## so callers can refresh the cache layer-by-layer toward fromFile.
  ## Returns empty seq if directly connected or no path exists.
  ## Uses BFS to guarantee the shortest path (fewest intermediate hops).
  var visited: HashSet[FilePathAbs]
  var parent: Table[FilePathAbs, FilePathAbs]
  var queue: seq[FilePathAbs] = @[fromFile]
  var head = 0
  visited.incl(fromFile)
  while head < queue.len:
    let current = queue[head]
    inc head
    if current == toFile:
      var path: seq[FilePathAbs]
      var node = current
      while node != fromFile:
        path.add(node)
        node = parent[node]
      path.add(fromFile)
      path.reverse()
      if path.len > 2:
        result = path[1..^2]
        result.reverse()
      break

    for dep in graph.getOrDefault(current, @[]):
      if dep notin visited:
        visited.incl(dep)
        parent[dep] = current
        queue.add(dep)

proc getDependencyPaths*(
  fileJustChangedUri: FileUri,
  dependencies: Forest,
  openFiles: seq[FileUri],
): seq[seq[FilePathAbs]] = 
  result = @[]
  ## This function is run directly after a successful Nimsuggest query (query) has been run and a response has been received.  This function returns the set of ordered dependency paths to traverse.
  let fileJustChangedPath = toFilePathAbs(fileJustChangedUri)

  var dependentFiles: seq[FilePathAbs] = @[]

  for openFile in openFiles:
    if openFile != fileJustChangedUri:
      let fileToCheck = toFilePathAbs(openFile)
      let thisFileDependsOnFileJustChanged = dependencies.trees.checkDependency(fileJustChangedPath.isADependencyOf(fileToCheck))

      if thisFileDependsOnFileJustChanged:
        dependentFiles.add(fileToCheck)

  for f in dependentFiles:
    let intermediates: seq[FilePathAbs] = findIntermediatePathBfs(
      dependencies.trees,
      f, 
      fileJustChangedPath
    )
    result.add(concat(intermediates, @[f]))

proc topoSort*(
  nodes: seq[FilePathAbs], graph: Table[FilePathAbs, seq[FilePathAbs]]
): seq[FilePathAbs] =
  let nodeSet = nodes.toHashSet()

  # Build in-degree count: how many things in our set does each node import?
  # (i.e. how many of its prerequisites are still pending)
  var inDegree: Table[FilePathAbs, int]
  var dependents: Table[FilePathAbs, seq[FilePathAbs]]  # reverse edges within subset

  for n in nodes:
    if n notin inDegree: inDegree[n] = 0
    for dep in graph.getOrDefault(n, @[]):
      if dep in nodeSet:                # only count edges within our subset
        inDegree[n] += 1
        dependents.mgetOrPut(dep, @[]).add(n)

  # Seed queue with nodes that have no in-subset dependencies → compile first
  var queue: Deque[FilePathAbs]
  for n in nodes:
    if inDegree[n] == 0:
      queue.addLast(n)

  var output: seq[FilePathAbs]
  while queue.len > 0:
    let n = queue.popFirst()
    output.add(n)
    for dependent in dependents.getOrDefault(n, @[]):
      inDegree[dependent] -= 1
      if inDegree[dependent] == 0:
        queue.addLast(dependent)

  # If result.len < nodes.len there's a cycle — shouldn't happen in valid Nim
  return output

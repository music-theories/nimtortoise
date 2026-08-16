import std/[os, strutils, tables, sets, json, sequtils, options]
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

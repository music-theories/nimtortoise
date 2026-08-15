import std/[os, strutils, tables, sets, json, sequtils]

type
  VisitState* = enum
    unvisited, visiting, visited

  DependencyGraph* = object
    graph*: Table[string, seq[string]]
    states*: Table[string, VisitState]
    stack*: seq[string]
    root*: string

proc normalizePath(path: string): string =
  result = absolutePath(path).normalizedPath

proc displayPath(path, root: string): string =
  relativePath(path, root).replace('\\', '/')

proc cleanName(raw: string): string =
  ## Strip "as alias", "except ...", and trailing ";..." suffixes from a module
  ## name token.  Semicolons begin a new statement (e.g. "import foo; export foo").
  var name = raw.strip()
  let semiPos = name.find(';')
  if semiPos >= 0:
    name = name[0 ..< semiPos].strip()
  let asPos = name.find(" as ")
  if asPos >= 0:
    name = name[0 ..< asPos].strip()
  let exceptPos = name.find(" except ")
  if exceptPos >= 0:
    name = name[0 ..< exceptPos].strip()
  result = name

proc expandGroup(group: string, output: var seq[string]) =
  ## Expand one import group, which is either:
  ##   foo                   -- simple name
  ##   foo as bar            -- aliased name
  ##   prefix/[a, b, c]      -- bracket list with optional path prefix
  let bracketPos = group.find('[')
  if bracketPos < 0:
    let name = cleanName(group)
    if name.len > 0:
      output.add(name)
  else:
    let prefix = group[0 ..< bracketPos]          # e.g. "std/" or "../utils/"
    let closePos = group.find(']', bracketPos)
    let inside =
      if closePos > bracketPos: group[bracketPos + 1 ..< closePos]
      else:                     group[bracketPos + 1 .. ^1]
    for item in inside.split(','):
      let name = cleanName(item)
      if name.len > 0:
        output.add(prefix & name)

proc extractImports(source: string): seq[string] =
  ## Extract module names from common Nim import syntax:
  ##
  ##   import foo, bar/baz
  ##   import std/[os, strutils]          ← single-line bracket
  ##   import ../utils/[a as u, b]
  ##   from foo import x
  ##   import                             ← bare multi-line form
  ##     foo, bar
  ##   import ./[                         ← multi-line bracket form
  ##     foo, bar,
  ##     baz
  ##   ]
  ##
  ## This is not a complete Nim parser; it covers the patterns used in
  ## typical project code.

  var inMultiline = false    # true after a bare "import" line
  var inBracket = false      # true inside a multi-line bracket import
  var bracketPrefix = ""     # path prefix before "[", e.g. "./" or "../utils/"

  for line in source.splitLines:
    let stripped = line.strip()

    # ── multi-line bracket mode ──────────────────────────────────────────────
    if inBracket:
      let closePos = stripped.find(']')
      let content = if closePos >= 0: stripped[0 ..< closePos] else: stripped
      let cleaned = content.strip(chars = {',', ' '})
      if cleaned.len > 0 and not cleaned.startsWith('#'):
        for item in cleaned.split(','):
          let name = cleanName(item)
          if name.len > 0:
            result.add(bracketPrefix & name)
      if closePos >= 0:
        inBracket = false
        bracketPrefix = ""
      continue

    # ── bare multi-line mode ─────────────────────────────────────────────────
    if inMultiline:
      # A non-indented (or empty) line ends the block.
      if line.len > 0 and line[0] notin {' ', '\t'}:
        inMultiline = false
        # Fall through: re-process this line as a normal statement.
      else:
        let content = stripped.strip(chars = {','})
        if content.len > 0 and not content.startsWith('#'):
          for item in content.split(','):
            expandGroup(item.strip(), result)
        continue

    if stripped == "import":
      inMultiline = true
      continue

    # ── normal import line ───────────────────────────────────────────────────
    if stripped.startsWith("import "):
      let imports = stripped[7 .. ^1]

      # Detect a multi-line bracket: "[" present but "]" absent or before "[".
      let openPos  = imports.find('[')
      let closePos = imports.find(']')
      if openPos >= 0 and closePos < openPos:
        # Opening bracket not closed on this line — enter bracket mode.
        bracketPrefix = imports[0 ..< openPos]
        let afterOpen = imports[openPos + 1 .. ^1].strip(chars = {',', ' '})
        if afterOpen.len > 0 and not afterOpen.startsWith('#'):
          for item in afterOpen.split(','):
            let name = cleanName(item)
            if name.len > 0:
              result.add(bracketPrefix & name)
        inBracket = true
      else:
        # Balanced (single-line) import — split at top-level commas only.
        var depth = 0
        var current = ""
        for c in imports:
          case c
          of '[': inc depth; current.add(c)
          of ']': dec depth; current.add(c)
          of ',':
            if depth == 0:
              expandGroup(current.strip(), result)
              current = ""
            else:
              current.add(c)
          else:
            current.add(c)
        expandGroup(current.strip(), result)

    elif stripped.startsWith("from "):
      let rest = stripped[5 .. ^1]
      let importPos = rest.find(" import")
      if importPos >= 0:
        let name = rest[0 ..< importPos].strip()
        if name.len > 0:
          result.add(name)

proc resolveImport(
  importName: string,
  importingFile: string,
  root: string
): string =
  ## Nim modules normally correspond to:
  ##
  ##   foo        -> foo.nim
  ##   foo/bar    -> foo/bar.nim
  ##
  ## First try relative to the importing file, then the project root.

  # If the name already contains a path separator it is already a filesystem
  # path (e.g. "std/os", "../utils/utils", "./foo").  Only convert dots to
  # separators for dot-qualified names that have no slashes (e.g. "sub.module").
  let modulePath =
    if '/' in importName or '\\' in importName: importName
    else: importName.replace('.', DirSep)

  let candidates = [
    joinPath(parentDir(importingFile), modulePath & ".nim"),
    joinPath(root, modulePath & ".nim")
  ]

  for candidate in candidates:
    let normalized = normalizePath(candidate)
    if fileExists(normalized):
      return normalized

  # Empty means "not a project-local dependency".
  return ""

proc isDependency*(
  graph: Table[string, seq[string]],
  rootFile: string,
  dependencyFile: string
): bool =
  ## Returns true if dependencyFile is a direct or transitive dependency
  ## of rootFile (i.e. rootFile imports it, directly or indirectly).
  var visited: HashSet[string]
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
  graph: Table[string, seq[string]],
  rootFile: string,
  dependentFile: string
): bool =
  ## Returns true if rootFile is a direct or transitive dependency of
  ## dependentFile (i.e. dependentFile imports rootFile, directly or indirectly).
  isDependency(graph, dependentFile, rootFile)

proc visit(
  dependencyGraph: var DependencyGraph,
  file: string, root: string,
) =
  let file = normalizePath(file)

  case dependencyGraph.states.getOrDefault(file, unvisited)

  of visited:
    return

  of visiting:
    let cycleStart = dependencyGraph.stack.find(file)
    var cycle = dependencyGraph.stack[cycleStart .. ^1]
    cycle.add(file)

    raise newException(
      ValueError,
      "Circular dependency detected:\n  " &
      cycle.mapIt(displayPath(it, root)).join(" -> ")
    )

  of unvisited:
    dependencyGraph.states[file] = visiting
    dependencyGraph.stack.add(file)

    if not dependencyGraph.graph.hasKey(file):
      dependencyGraph.graph[file] = @[]

    let source = readFile(file)

    for importName in extractImports(source):
      let dependency = resolveImport(importName, file, root)

      if dependency.len == 0:
        # Not a project-local .nim file; treat it as a standard library
        # or external dependency and ignore it.
        continue

      if dependency notin dependencyGraph.graph[file]:
        dependencyGraph.graph[file].add(dependency)

      dependencyGraph.visit(dependency, root)

    discard dependencyGraph.stack.pop()
    dependencyGraph.states[file] = visited

proc formatInJson*(dependencyGraph: DependencyGraph): string = 
  var output = newJObject()
  for file, dependencies in dependencyGraph.graph.pairs:
    let key = displayPath(file, dependencyGraph.root)
    var deps = newJArray()

    for dependency in dependencies:
      deps.add(%*displayPath(dependency, dependencyGraph.root))

    output[key] = deps
  return pretty(output)

proc initDependencyGraph*(entryFile: string): DependencyGraph =
  result = DependencyGraph(
    graph: initTable[string, seq[string]](),
    states: initTable[string, VisitState](),
    stack: @[],
    root: ""
  ) 
  let entry = normalizePath(entryFile)

  if not fileExists(entry):
    quit("File not found: " & paramStr(1), 1)

  if splitFile(entry).ext != ".nim":
    quit("Input must be a .nim file: " & paramStr(1), 1)

  result.root = parentDir(entry)

  try:
    result.visit(entry, result.root)
  except CatchableError as e:
    quit(e.msg, 1)

when isMainModule:
  if paramCount() != 1:
    quit("Usage: nimdeps <path/to/file.nim>", 1)

  var dependencyGraph = initDependencyGraph(paramStr(1))
  echo formatInJson(dependencyGraph)
  
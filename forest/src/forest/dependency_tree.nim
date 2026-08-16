import std/[os, strutils, tables, sets, json, sequtils, options]
import ../resources/resources
import ./[forest_types]

proc normalizePath(path: string): FilePathAbs =
  FilePathAbs(absolutePath(path).normalizedPath)

proc displayPath(path: FilePathAbs, root: DirPathAbs): string =
  relativePath(string(path), string(root)).replace('\\', '/')

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

proc extractImports*(source: string): seq[string] =
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
  importName:    string,
  importingFile: FilePathAbs,
  root:          DirPathAbs,
): Option[FilePathAbs] =
  ## Nim modules normally correspond to:
  ##
  ##   foo        -> foo.nim
  ##   foo/bar    -> foo/bar.nim
  ##
  ## Resolution order:
  ##   1. Relative to the importing file's directory
  ##   2. Relative to the project root

  # If the name already contains a path separator it is already a filesystem
  # path (e.g. "std/os", "../utils/utils", "./foo").  Only convert dots to
  # separators for dot-qualified names that have no slashes (e.g. "sub.module").
  let modulePath =
    if '/' in importName or '\\' in importName: importName
    else: importName.replace('.', DirSep)

  let relativeToFile = normalizePath(joinPath(parentDir(string(importingFile)), modulePath & ".nim"))
  if fileExists(string(relativeToFile)):
    return some(relativeToFile)

  let relativeToRoot = normalizePath(joinPath(string(root), modulePath & ".nim"))
  if fileExists(string(relativeToRoot)):
    return some(relativeToRoot)

  none(FilePathAbs)

proc visit(
  dependencyGraph: var DependencyGraph,
  file: FilePathAbs,
  root: DirPathAbs,
) =
  let file = normalizePath(string(file))

  var currentState = VisitState.UNVISITED
  if file in dependencyGraph.states:
    currentState = dependencyGraph.states[file]

  case currentState
  of VISITED:
    return

  of VISITING:
    let cycleStart = dependencyGraph.stack.find(file)
    var cycle = dependencyGraph.stack[cycleStart .. ^1]
    cycle.add(file)

    raise newException(
      ValueError,
      "Circular dependency detected:\n  " &
      cycle.mapIt(displayPath(it, root)).join(" -> ")
    )

  of UNVISITED:
    dependencyGraph.states[file] = VISITING
    dependencyGraph.stack.add(file)

    if not dependencyGraph.graph.hasKey(file):
      dependencyGraph.graph[file] = @[]

    let source = readFile(string(file))

    for importName in extractImports(source):
      let dependency = resolveImport(importName, file, root)

      if dependency.isNone:
        # Not a project-local .nim file; treat it as a standard library
        # or external dependency and ignore it.
        continue

      let dep = dependency.get
      if dep notin dependencyGraph.graph[file]:
        dependencyGraph.graph[file].add(dep)

      dependencyGraph.visit(dep, root)

    discard dependencyGraph.stack.pop()
    dependencyGraph.states[file] = VISITED

proc formatInJson*(dependencyGraph: DependencyGraph): string =
  var output = newJObject()
  for file, dependencies in dependencyGraph.graph.pairs:
    let key = displayPath(file, dependencyGraph.root)
    var deps = newJArray()

    for dependency in dependencies:
      deps.add(%*displayPath(dependency, dependencyGraph.root))

    output[key] = deps
  return pretty(output)

proc commonParentDir(paths: seq[DirPathAbs]): DirPathAbs =
  ## Returns the longest common directory prefix of all paths.
  if paths.len == 0: return DirPathAbs("")
  var parts = string(paths[0]).split(DirSep)
  for path in paths[1 .. ^1]:
    let p = string(path).split(DirSep)
    var i = 0
    while i < parts.len and i < p.len and parts[i] == p[i]:
      inc i
    parts = parts[0 ..< i]
  DirPathAbs(parts.join($DirSep))

proc initDependencyGraph*(
  entryFiles: seq[FilePathAbs],
  root:       DirPathAbs
): DependencyGraph =
  ## Build a dependency graph from one or more entry .nim files.
  ## If root is empty it is inferred as the common parent directory of all
  ## entry files (suitable for a multi-package repo).
  result = DependencyGraph(
    graph:  initTable[FilePathAbs, seq[FilePathAbs]](),
    states: initTable[FilePathAbs, VisitState](),
    stack:  @[],
    root:   DirPathAbs("")
  )

  var entries: seq[FilePathAbs]
  for f in entryFiles:
    if not fileExists(string(f)):
      quit("File not found: " & string(f), 1)
    if splitFile(string(f)).ext != ".nim":
      quit("Input must be a .nim file: " & string(f), 1)
    entries.add(f)

  result.root =
    if string(root).len > 0: root
    else: commonParentDir(entries.mapIt(parentDir(it)))

  try:
    for entry in entries:
      result.visit(entry, result.root)
  except CatchableError as e:
    quit(e.msg, 1)

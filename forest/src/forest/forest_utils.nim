import std/[os, strutils, tables, json, jsonutils]
import chronos
import ./[forest_types]
import ../resources/resources

proc getAllFiles*(rootPath: DirPathAbs, suffix: string): seq[FilePathAbs] =
  # Full recursive search across all subdirectory levels.
  let ext = suffix[1..^1]  # strip leading '*' from e.g. "*.nimble"
  for p in walkDirRec(string(rootPath), yieldFilter = {pcFile}):
    if p.endsWith(ext):
      result.add(FilePathAbs(p))

proc getAllNimsFiles*(rootPath: DirPathAbs): seq[FilePathAbs] =
  getAllFiles(rootPath, "*.nims")


proc toJsonHook*(f: Forest): JsonNode =
  result = newJObject()
  result["root"] = newJString(string(f.root))

  let nimble = newJObject()
  for k, d in f.nimble.pairs:
    let entry = newJObject()
    entry["name"] = newJString(d.name)
    let eps = newJArray()
    for p in d.entryPoints: eps.add newJString(string(p))
    entry["entryPoints"] = eps
    entry["testEntryPoint"] = newJString(string(d.testEntryPoint))
    nimble[string(k)] = entry
  result["nimble"] = nimble

  let paths = newJObject()
  for k, ps in f.paths.pairs:
    let arr = newJArray()
    for p in ps: arr.add newJString(string(p))
    paths[string(k)] = arr
  result["paths"] = paths

  let trees = newJObject()
  for k, deps in f.trees.pairs:
    let arr = newJArray()
    for d in deps: arr.add newJString(string(d))
    trees[string(k)] = arr
  result["trees"] = trees

proc debugStr*(f: Forest): string =
  var lines: seq[string]
  let root = string(f.root)

  proc rel(p: string): string =
    relativePath(p, root)

  # --- Nimble dump ---
  lines.add "=== Nimble ==="
  if f.nimble.len == 0:
    lines.add "  (none)"
  else:
    for (k, d) in f.nimble.pairs:
      lines.add "  [" & rel(string(k)) & "]"
      lines.add "    name: " & d.name
      if d.entryPoints.len > 0:
        lines.add "    entryPoints:"
        for p in d.entryPoints:
          lines.add "      " & string(p)
      if d.testEntryPoint != FilePathRel(""):
        lines.add "    testEntryPoint: " & string(d.testEntryPoint)

  # --- Paths (lib/search paths per entry point) ---
  lines.add ""
  lines.add "=== Paths ==="
  if f.paths.len == 0:
    lines.add "  (none)"
  else:
    for (k, ps) in f.paths.pairs:
      lines.add "  [" & rel(string(k)) & "]"
      for p in ps:
        lines.add "    " & rel(string(p))

  # --- Trees (dependency graph per entry point) ---
  lines.add ""
  lines.add "=== Trees ==="
  if f.trees.len == 0:
    lines.add "  (empty)"
  else:
    for (k, deps) in f.trees.pairs:
      if deps.len == 0:
        lines.add "  " & rel(string(k)) & " -> (no deps)"
      else:
        lines.add "  " & rel(string(k)) & " ->"
        for d in deps:
          lines.add "    " & rel(string(d))

  result = lines.join("\n")

##[
Path: a filesystem path string, e.g.
/Users/dp/projects/monorepo/pkga/src/pkga.nim
URI: an LSP file URI, e.g.
file:///Users/dp/projects/monorepo/pkga/src/pkga.nim
The URI has the file:// scheme prefix. uriToPath strips it; pathToUri adds it.
]##

import std/[os, sequtils, strutils, tables]
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


proc debugStr*(f: Forest): string =
  var lines: seq[string]
  let root = string(f.dependencies.root)

  proc rel(p: string): string =
    relativePath(p, root)

  # --- NimbleInfo ---
  lines.add "=== NimbleInfo ==="
  lines.add "  dump:"
  if f.nimble.dump.len == 0:
    lines.add "    (none)"
  else:
    for (k, d) in f.nimble.dump.pairs:
      lines.add "    [" & rel(string(k)) & "]"
      lines.add "      name: " & d.name
      if d.entryPoints.len > 0:
        lines.add "      entryPoints:"
        for p in d.entryPoints:
          lines.add "        " & string(p)
      if d.testEntryPoint != FilePathRel(""):
        lines.add "      testEntryPoint: " & string(d.testEntryPoint)

  # --- NimDumpInfo per file (libPaths inside root only) ---
  lines.add ""
  lines.add "=== Nim dump (per file) ==="
  if f.nim.len == 0:
    lines.add "  (none)"
  else:
    for (k, d) in f.nim.pairs:
      let localLibPaths = d.libPaths.filterIt(string(it).startsWith(root))
      lines.add "  [" & rel(string(k)) & "]"
      if localLibPaths.len > 0:
        lines.add "    libPaths:"
        for p in localLibPaths:
          lines.add "      " & rel(string(p))
      else:
        lines.add "    libPaths: (none inside root)"

  # --- DependencyGraph (graph only, relative paths) ---
  lines.add ""
  lines.add "=== DependencyGraph ==="
  if f.dependencies.graph.len == 0:
    lines.add "  (empty)"
  else:
    for (k, deps) in f.dependencies.graph.pairs:
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

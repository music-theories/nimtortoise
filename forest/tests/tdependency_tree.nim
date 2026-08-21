import std/[os, tables, unittest]
import forest

let entryFile = FilePathAbs(
  absolutePath(currentSourcePath().parentDir() / ".." / ".." / "langserver" / "src" / "nimtortoise.nim")
)
let dg = initDependencyGraph(@[entryFile], DirPathAbs(""))

proc p(rel: string): FilePathAbs =
  ## Absolute path for a src-relative filename, matching the graph's keys.
  FilePathAbs(absolutePath(string(dg.root) / rel).normalizedPath)

suite "isDependency":

  test "direct dependency":
    # nimtortoise.nim explicitly imports protocol/types
    check isDependency(dg.graph, p("nimtortoise.nim"), p("protocol/types.nim"))

  test "transitive dependency":
    # nimtortoise.nim -> langserver/dispatcher.nim -> nph/formatting.nim
    # (nph/formatting is NOT a direct import of nimtortoise)
    check not (p("nph/formatting.nim") in dg.graph[p("nimtortoise.nim")])
    check isDependency(dg.graph, p("nimtortoise.nim"), p("nph/formatting.nim"))

  test "non-dependency returns false":
    # protocol/primitives.nim is a leaf — nimtortoise is not its dependency
    check not isDependency(dg.graph, p("protocol/primitives.nim"), p("nimtortoise.nim"))

  test "leaf node has no dependencies":
    # utils/process_utils.nim and protocol/primitives.nim are leaves
    check not isDependency(dg.graph, p("utils/process_utils.nim"), p("protocol/types.nim"))
    check not isDependency(dg.graph, p("protocol/primitives.nim"), p("protocol/types.nim"))

suite "isDependent":

  test "nimtortoise is dependent on protocol/types":
    check isDependent(dg.graph, p("protocol/types.nim"), p("nimtortoise.nim"))

  test "transitive: dispatcher depends on protocol/types":
    check isDependent(dg.graph, p("protocol/types.nim"), p("langserver/dispatcher.nim"))

  test "non-dependent returns false":
    check not isDependent(dg.graph, p("nimtortoise.nim"), p("protocol/types.nim"))

  test "isDependent is the inverse of isDependency":
    let a = p("nimtortoise.nim")
    let b = p("nph/formatting.nim")
    check isDependency(dg.graph, a, b) == isDependent(dg.graph, b, a)
    check isDependency(dg.graph, b, a) == isDependent(dg.graph, a, b)

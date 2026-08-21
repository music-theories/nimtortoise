import os, std/asyncnet, strutils, chronos, chronos/asyncproc, options

import unittest2

import ../src/nimsuggest/nimsuggest
import ../src/protocol/types

## tsuggestapi.nim — rewrite-compatible port of tests/tsuggestapi.nim
##
## The suggestapi layer is largely unchanged; only the import path moves.
## createNimsuggest still returns Future[Project]; Project.ns is Future[NimSuggest].
## project.process and project.errorCallback still exist on Project.
## 
const inputLine = "def	skProc	hw.a	proc (){.noSideEffect, gcsafe.}	hw/hw.nim	1	5	\"\"	100"
const inputLineWithEndLine = "outline	skEnumField	system.bool.true	bool	basic_types.nim	46	15	\"\"	100	4	11"

suite "Nimsuggest tests":
  let
    helloWorldFile = FilePathAbs(getCurrentDir() / "tests/projects/hw/hw.nim")
    nimSuggest = createNimsuggest(
      NimsuggestSpawnInfo(
        entryPoint: helloWorldFile,
        workingDir: DirPathAbs(getCurrentDir()),
        nimbleFile: none(FilePathAbs),
        paths: @[],
      ),
      NimsuggestSettings(
        exePath: FilePathAbs("nimsuggest"),
        protocol: HighestSupportedNimSuggestProtocolVersion,
        capabilities: {},
      ),
      120_000, false,
    ).waitFor

  test "Parsing qualified path":
    echo "    >> Parsing qualified path"
    doAssert parseQualifiedPath("a.b.c") == @["a", "b", "c"]
    doAssert parseQualifiedPath("system.`..<`") == @["system", "`..<`"]

  test "Parsing suggest":
    echo "    >> Parsing suggest"
    doAssert parseSuggestDef(inputLine).get[] == Suggest(
      filePath: FilePathAbs("hw/hw.nim"),
      qualifiedPath: @["hw", "a"],
      symKind: "skProc",
      line: 1,
      column: 5,
      doc: "",
      forth: "proc (){.noSideEffect, gcsafe.}",
      section: ideDef)[]

  test "Parsing suggest with endLine":
    echo "    >> Parsing suggest with endLine"
    let res = parseSuggestDef(inputLineWithEndLine).get
    doAssert res[] == Suggest(
      filePath: FilePathAbs("basic_types.nim"),
      qualifiedPath: @["system", "bool", "true"],
      symKind: "skEnumField",
      line: 46,
      column: 15,
      doc: "",
      forth: "bool",
      section: ideOutline,
      endLine: 4,
      endCol: 11
    )[]

  test "test Nimsuggest.call":
    echo "    >> test Nimsuggest.call"
    let res = waitFor nimSuggest.call("def", helloWorldFile, helloWorldFile, 2, 10)
    doAssert res.len == 1
    doAssert res[0].forth.contains("noSideEffect")

  test "test Nimsuggest.def":
    echo "    >> test Nimsuggest.def"
    let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 2, 10)
    doAssert res.len == 1
    doAssert res[0].forth.contains("proc")

  test "test Nimsuggest.sug":
    echo "    >> test Nimsuggest.sug"
    let res = waitFor nimSuggest.sug(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len > 1
    doAssert res[0].forth == "proc ()"

  test "test Nimsuggest.known":
    echo "    >> test Nimsuggest.known"
    let res = waitFor nimSuggest.known(helloWorldFile)
    doAssert res[0].forth == "true"


suite "Nimsuggest error handling":
  test "a dying nimsuggest fires the error callback exactly once":
    echo "    >> a dying nimsuggest fires the error callback exactly once"
    # Regression test for #428: markFailed fired errorCallback on every call,
    # so one crash triggered it once per failure path (closed socket in
    # processQueue + stderr EOF in logNsError) and the server restarted the
    # same project twice, concurrently. Suspend the child before issuing a
    # command so the command is in flight when the process is killed and both
    # paths run deterministically.
    let helloWorldFile = FilePathAbs(getCurrentDir() / "tests/projects/hw/hw.nim")
    let ns = createNimsuggest(
      NimsuggestSpawnInfo(
        entryPoint: helloWorldFile,
        workingDir: DirPathAbs(getCurrentDir()),
        nimbleFile: none(FilePathAbs),
        paths: @[],
      ),
      NimsuggestSettings(
        exePath: FilePathAbs("nimsuggest"),
        protocol: HighestSupportedNimSuggestProtocolVersion,
        capabilities: {},
      ),
      120_000, false,
    ).waitFor

    discard ns.process.suspend()
    let fut = ns.def(helloWorldFile, FilePathAbs(""), 2, 10)
    waitFor sleepAsync(200)
    discard ns.process.kill()

    # Fix #17: socket-close no longer fails the future; it completes with @[].
    # ns.failed is set by markFailed, which fires once on crash.
    let res = waitFor fut
    check res.len == 0
    waitFor sleepAsync(300)

    check ns.failed == true

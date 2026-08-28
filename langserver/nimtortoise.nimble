mode = ScriptMode.Verbose

packageName = "nimtortoise"
version = "0.3.2"
author = "David Pocknee"
description = "Fork and rewrite of the nim language server for IDEs"
license = "MIT"
srcDir = "src"
bin = @["nimtortoise"]
binDir = "bin"
skipDirs = @["tests"]

requires "nim >= 2.0.8",
  "chronos >= 4.0.4", "json_rpc >= 0.5.0",  "chronicles", "serialization",
  "json_serialization", "stew", "unittest2 >= 0.2.4"

--path:
  "."

import std/os

task test, "run tests":
  let helpers = [
    "all.nim", "testhelpers.nim", "tbughelpers.nim",
    "fixhelpers.nim", "client_utils.nim", "lspsocketclient.nim"
  ]
  for f in listFiles(thisDir() / "tests"):
    let name = f.lastPathPart
    if name.endsWith(".nim") and name notin helpers:
      exec "nim c -d:chronicles_log_level=ERROR -r -w:off --path:. -o:bin/" & name[0 ..< name.len - 4] & " " & f

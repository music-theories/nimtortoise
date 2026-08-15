# Package

version       = "0.1.3"
author        = "David Pocknee"
description   = "A library to map and traverse the dependency trees of nim files."
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["nimforest"]
entryPoints   = @["src/nimforest.nim", "tests/tdependency_tree.nim"]
# testEntryPoint = "tests/tdependency_tree.nim"

# Dependencies

requires "nim >= 2.0.8"

task test, "test":
  exec "nim c -r -o:bin/tdependency_tree tests/tdependency_tree.nim"

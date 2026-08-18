# Package

version       = "0.1.4"
author        = "David Pocknee"
description   = "A library to map and traverse the dependency trees of nim files."
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["forest"]
installExt    = @["nim"]
entryPoints   = @["src/forest.nim", "tests/tdependency_tree.nim"]
# testEntryPoint = "tests/tdependency_tree.nim"

# Dependencies

requires "nim >= 2.0.8",
  "chronos >= 4.0.4", "chronicles", "stew"

task test, "test":
  exec "nim c -r -o:bin/tdependency_tree tests/tdependency_tree.nim"

task dumpTest, "Try out nimble dump":
  exec "nim c -r -o:bin/nimforest_nimble src/nimforest/nimforest_nimble.nim"
 
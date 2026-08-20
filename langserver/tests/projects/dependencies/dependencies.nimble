# Package

version       = "0.1.0"
author        = "David Pocknee"
description   = "Test for transitive dependencies"
license       = "MIT"
srcDir        = "src"
bin           = @["dependencies"]
bindir        = "bin"
entryPoints   = @["src/dependencies.nim"]

# Dependencies

requires "nim >= 2.2.10"

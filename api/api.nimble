# Package

version       = "0.3.2"
author        = "David Pocknee"
description   = "Just a shared package that contains the necessary components both the language server and VS Code extension need."
license       = "MIT"
srcDir        = "src"
bin           = @["api"]


# Dependencies

requires "nim >= 2.2.10"

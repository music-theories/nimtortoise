# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

switch("path", thisDir() & "/../forest/src")
switch("path", thisDir() & "/../api/src")

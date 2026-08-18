
# proc getNimVersion*(nimDir: string): string =
#   let cmd =
#     if nimDir == "":
#       "nim --version"
#     else:
#       nimDir / "nim --version"
#   let info = execProcess(cmd)
#   const NimCompilerVersion = "Nim Compiler Version "
#   for line in info.splitLines:
#     if line.startsWith(NimCompilerVersion):
#       return line

# proc getNimPath*(conf: NlsConfig): Option[string] =
#   if string(conf.nimsuggestPath).len > 0 and fileExists(conf.nimsuggestPath):
#     return some(parentDir(string(conf.nimsuggestPath)) / "nim")
#   else:
#     let path = findExe("nim")
#     if path != "":
#       return some(path)
#     else:
#       warn "Failed to find nim path"
#       return none(string)

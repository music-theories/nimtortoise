import std/[options, tables, os, sequtils, strutils, times]
import chronos
import chronos/asyncproc
import stew/byteutils
import chronicles
import ../nimble/[nimble, nimble_utils, nimble_types]
import ../nim_compiler/nim_compiler
import ../configurations/configurations
import ../nimsuggest/nimsuggest
import ../utils/[process_utils]
import ../utils/utils
import ./[langserver_types, langserver_utils]
import ../protocol/types

# proc initNimsuggestInstances*(ls: LanguageServer) {.async.} =
#   ## Starts nimsuggest instances.
#   # let rootPath = getRootPath(ls.capabilities.lspInitializeParams)
#   # let rootPath = getRootPath(ls.capabilities.lspInitializeParams)

#   if rootPath.isSome():
#     let foundRootPath = rootPath.get()
#     debug "initNimsuggestInstances: rootPath found.", found = foundRootPath
#     ls.files.rootPath = foundRootPath

#   else:
#     debug "initNimsuggestInstances: no rootPath found.  Quitting."
#     return 

#   let config = ls.configurations.currentConfig

#   # Update pool settings from config (pool was created with defaults in initLanguageServer)
#   ls.pool.maxSlots = config.maxNimsuggestProcesses
#   ls.pool.fileCheckDelay = initDuration(milliseconds = config.fileCheckDelay)


#   # Get all nimble information
#   let foundNimbleFiles: seq[FilePath] = searchForNimbleFiles(ls.files.rootPath)
#   var nimsuggestSet = false

#   for i, nimbleFile in foundNimbleFiles:
#     let nimbleDumpInfo: NimbleDumpInfo = await getNimbleDumpInfo(ls.nimbleDumpCache, nimbleFile)

#     if not(nimbleFile in ls.nimbleDumpCache):
#       ls.nimbleDumpCache[nimbleFile] = nimbleDumpInfo

#     if nimsuggestSet == false:
#       # Resolve the nimsuggest binary path and Nim version now that config is available.
#       let (nimsuggestPath, nimVersion) = await getNimSuggestPathAndVersion(nimbleDumpInfo, config)
#       ls.pool.nimVersion = nimVersion
#       let nsPath = toFilePath(nimsuggestPath)

#       ls.pool.nimsuggestPath = nsPath
#       ls.pool.nimsuggestProtocol = detectNimsuggestProtocolVersion(nsPath)
#       ls.pool.nimsuggestCapabilities = getNimsuggestCapabilities(nsPath)

#       nimsuggestSet = true

# proc getEntryPoints(
#   ls: LanguageServer, rootPath: string
# ): Future[seq[FilePath]] {.async.}  = 
#   # Discover entry points via nimble dump.
#   # Search rootPath first, then one level of subdirectories (handles workspaces
#   # where the nimble project root is a subfolder of the opened workspace).
#   let nimbleFiles = searchForNimbleFiles(rootPath)

#   if nimbleFiles.len > 0:
#     debug "Found nimble files ", nimbleFiles = nimbleFiles
#     let nimbleFile = FilePath(nimbleFiles[0]) # Why only the first file?
#     # Use the nimble file's parent directory as the project root, not the
#     # workspace root — they may differ when the project is in a subfolder.
#     debug "Starting nimble dump for", nimbleFile = $nimbleFile
#     let nimbleDumpInfo: NimbleDumpInfo = await getNimbleDumpInfo(ls.nimbleDumpCache, nimbleFile)

#     if nimbleDumpInfo.nimblePath.isSome:
#       let nimblePathToUse = FilePath(nimbleDumpInfo.nimblePath.get())
#       ls.nimbleDumpCache[nimblePathToUse] = nimbleDumpInfo
#     else:
#       ls.nimbleDumpCache[nimbleFile] = nimbleDumpInfo
    
#     let nimbleProjectRoot = parentDir(string(nimbleFile))
#     let entryPoints = nimbleDumpInfo.getNimbleEntryPoints(nimbleProjectRoot).mapIt(FilePath(it))

#     debug "Finished nimble dump", nimbleFile = $nimbleFile
#     debug "Found the following entryPoints", entryPoints = $entryPoints
#     return entryPoints
#   else:
#     debug "Found no nimble files."
#     return @[]

     
# proc getNimSuggestPathAndVersion*(
#   ls: LanguageServer, conf: NlsConfig, workingDir: string
# ): Future[tuple[path: string, version: string]] {.async.} =
#   let nimblePath = ls.files.rootPath # FilePath("")
#   let nimbleDumpInfo: NimbleDumpInfo = await getNimbleDumpInfo(ls.nimbleDumpCache, nimblePath)

#   if string(nimbleDumpInfo.nimblePath).len > 0:
#     # let nimblePathToUse = FilePath(nimbleDumpInfo.nimblePath.get())
#     ls.nimbleDumpCache[nimbleDumpInfo.nimblePath] = nimbleDumpInfo
#   # else:
#   #   ls.nimbleDumpCache[nimblePath] = nimbleDumpInfo

#   # let nimsuggestInfo = getNimSuggestPathAndVersion(nimbleDumpInfo, conf)
#   let nimDir = nimbleDumpInfo.nimDir.get("")
#   var nimsuggestPath = expandTilde(conf.nimsuggestPath)
#   var nimVersion = ""
#   if nimsuggestPath == "":
#     if nimDir != "" and dirExists(nimDir):
#       nimVersion = getNimVersion(nimDir) & " from " & nimDir
#       nimsuggestPath = nimDir / "nimsuggest".addFileExt(ExeExt)
#     else:
#       nimVersion = getNimVersion("")
#       nimsuggestPath = findExe "nimsuggest"
#       # Fallback for restricted PATH environments (e.g. Dock launch on macOS where
#       # PATH is /usr/bin:/bin:/usr/sbin:/sbin and ~/.nimble/bin is not included,
#       # or Linux desktop launches that only source ~/.profile). Uses ExeExt so
#       # the check works on Windows ("nimsuggest.exe") too.
#       if nimsuggestPath == "":
#         let nimbleBinPath = getHomeDir() / ".nimble" / "bin" / "nimsuggest".addFileExt(ExeExt)
#         if fileExists(nimbleBinPath):
#           nimsuggestPath = nimbleBinPath
#   else:
#     nimVersion = getNimVersion(nimsuggestPath.parentDir)
#   debug "Using nimsuggest", nimVersion = nimVersion, path = nimsuggestPath
#   return (path: nimsuggestPath, version: nimVersion)
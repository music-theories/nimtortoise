import std/[tables]
import ../resources/resource_types

type
  VisitState* {.pure.} = enum
    UNVISITED, VISITING, VISITED

  DependencyGraph* = object
    graph*:  Table[FilePathAbs, seq[FilePathAbs]]
    states*: Table[FilePathAbs, VisitState]
    stack*:  seq[FilePathAbs]
    root*:   DirPathAbs

  Dependency* = object
    rootFile*:      FilePathAbs
    dependentFile*: FilePathAbs

type
  NimbleFile* = object
    entryPoints*: string

  NimRelatedFileKind* {.pure.} = enum
    NIMBLE, NIMBLE_PATHS, NIMBLE_LOCK,
    NIM_CFG, NIMS

  NimRelatedFile* = object
    case kind*: NimRelatedFileKind
    of NIMBLE: discard
    of NIMBLE_PATHS: discard
    of NIMBLE_LOCK: discard
    of NIM_CFG: discard
    of NIMS: discard

type
  NimbleVer* = object
    kind*: string   ## e.g. "verAny", "verEqLater", "verEq", etc.
    ver*:  string   ## empty when kind is "verAny"

  NimbleRequire* = object
    name*: string
    str*:  string   ## human-readable version string e.g. ">= 2.0.8"
    ver*:  NimbleVer

  NimbleDumpInfo* = object
    name*:         string
    version*:      string
    nimblePath*:   FilePathAbs
    author*:       string
    desc*:         string
    license*:      string
    skipDirs*:     seq[string]       ## glob patterns/names, not FS paths
    skipFiles*:    seq[string]       ## glob patterns/names
    skipExt*:      seq[string]       ## file extensions
    installDirs*:  seq[DirPathRel]
    installFiles*: seq[FilePathRel]
    installExt*:   seq[string]       ## file extensions
    requires*:     seq[NimbleRequire]
    bin*:          seq[string]       ## binary names, not paths
    binDir*:       DirPathRel        ## relative to nimble file dir
    srcDir*:       DirPathRel        ## relative to nimble file dir
    backend*:      string
    paths*:        seq[DirPathAbs]   ## absolute search paths from nimble
    nimDir*:       DirPathAbs
    entryPoints*:  seq[FilePathRel]  ## relative to nimble file dir
    testEntryPoint*: FilePathRel     ## relative to nimble file dir

type
  NimDumpInfo* = object
    version*:        string
    nimExe*:         FilePathAbs
    prefixDir*:      DirPathAbs
    libPath*:        DirPathAbs
    projectPath*:    DirPathAbs
    definedSymbols*: seq[string]
    libPaths*:       seq[DirPathAbs]
    lazyPaths*:      seq[DirPathAbs]
    outDir*:         DirPathAbs
    `out`*:          string          ## may be empty or a bare filename
    nimCache*:       DirPathAbs
    hints*:          Table[string, bool]
    warnings*:       Table[string, bool]

type
  NimbleInfo* = object
    files*: seq[FilePathAbs]
    dump*: Table[FilePathAbs, NimbleDumpInfo]
    entryPoints*: seq[FilePathAbs]

  Forest* = object
    nimble*: NimbleInfo
    nim*: Table[FilePathAbs, NimDumpInfo]
    dependencies*: DependencyGraph
    
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
  NimbleDumpInfo* = object
    name*:           string
    entryPoints*:    seq[FilePathRel]  ## relative to nimble file dir
    testEntryPoint*: FilePathRel       ## relative to nimble file dir

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
    
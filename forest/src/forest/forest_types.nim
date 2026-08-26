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

  NimInfo* = object
    version*:        string
    nimExe*:         FilePathAbs


type
  NimbleDumpInfo* = object
    name*:    string
    srcDir*:  DirPathRel
    bin*:     seq[FilePathRel]
    entryPoints*:    seq[FilePathRel]  ## relative to nimble file dir
    testEntryPoint*: FilePathRel       ## relative to nimble file dir

  NimbleInfo* = object
    # files*: seq[FilePathAbs]
    dump*: Table[FilePathAbs, NimbleDumpInfo]
    entryPoints*: seq[FilePathAbs]

type 
  Forest* = object
    root*:   DirPathAbs
    nim*:    NimInfo
    nimble*: NimbleInfo # Table[FilePathAbs, NimbleDumpInfo]
    paths*:  Table[FilePathAbs, seq[DirPathAbs]]
    trees*:  Table[FilePathAbs, seq[FilePathAbs]]
  
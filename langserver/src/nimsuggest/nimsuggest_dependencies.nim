import std/[sets, tables, sequtils]
import chronos
import chronicles

import forest


import ../configurations/configurations
import ../utils/utils
import ../protocol/types

import ./[suggestapi_types, nimsuggest_types]

proc createNimsuggestDependencyQueries*(
  query: NimsuggestQuery[NimsuggestFilePosition],
  storageDir: DirPathAbs,
  openFiles: TableRef[FileUri, NlsFileInfo],
  dependencies: Forest,
  config: NlsConfig
): seq[NimsuggestQuery[LspFilePosition]] = 
  ## This function is run directly after a successful Nimsuggest query (query) has been run and a response has been received.  This function generates a set of new queries to update the dependencies in order.
  result = @[]
  let dependencyPaths = getDependencyPaths(
    query.uri,
    dependencies,
    openFiles.keys.toSeq()
  )
  debug "dependencyPaths", paths = dependencyPaths
  
  let dependencyNodes = dependencyPaths
    .concat()
    .toHashSet().toSeq()   # deduplicate
  debug "dependencyNodes", nodes = dependencyNodes

  let checkDependents = config.performance.updateOnChange

  if dependencyNodes.len > 0:
    let sortedListOfDependencies = topoSort(
      dependencyNodes,
      dependencies.trees,
    )
    debug "sortedNodes", sorted = sortedListOfDependencies

    if checkDependents or query.saved:
      let startCheck = NimsuggestQuery[LspFilePosition](
        id: 0,
        kind: NimsuggestQueryKind.CHECK_FILE,
        isDependency: true,
        saved: false,
        uri: query.uri,
        dirtyFile: query.dirtyFile,
        responseFuture: newFuture[seq[Suggest]]("checkFile"),
      )
      result.add(startCheck)

      for f in sortedListOfDependencies:
        let fasUri = toUri(f)
        let stashLocation = if fasUri in openFiles: uriToStashFilePath(storageDir, fasUri) else: FilePathAbs("")
        let changedQuery = NimsuggestQuery[LspFilePosition](
          id: 0,
          kind: NimsuggestQueryKind.CHECK_FILE,
          isDependency: true,
          saved: false,
          uri: fasUri,
          dirtyFile:  stashLocation,
          responseFuture: newFuture[seq[Suggest]]("checkFile"),
        )
        result.add(changedQuery)

    else:
      for f in sortedListOfDependencies:
        let fasUri = toUri(f)
        let stashLocation = if fasUri in openFiles: uriToStashFilePath(storageDir, fasUri) else: FilePathAbs("")
        let changedQuery = NimsuggestQuery[LspFilePosition](
          id: 0,
          kind: NimsuggestQueryKind.CHANGED,
          isDependency: true,
          saved: false,
          uri: fasUri,
          dirtyFile:  stashLocation,
          responseFuture: newFuture[seq[Suggest]]("checkFile"),
        )
        result.add(changedQuery)

  elif query.saved:
    # No open dependents, but still check the saved file itself so stale
    # diagnostics from a previous state are replaced.
    result.add(NimsuggestQuery[LspFilePosition](
      id: 0,
      kind: NimsuggestQueryKind.CHECK_FILE,
      isDependency: true,
      saved: false,
      uri: query.uri,
      dirtyFile: query.dirtyFile,
      responseFuture: newFuture[seq[Suggest]]("checkFile"),
    ))

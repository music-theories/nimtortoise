import std/[os, sets, tables, sequtils, algorithm]
import chronos
import chronicles

import forest


import ../configurations/configurations
import ../utils/utils
import ../protocol/types

import ./[suggestapi_types, nimsuggest_utils, nimsuggest_types]

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

  if dependencyNodes.len > 0:
    let sortedListOfDependencies = topoSort(
      dependencyNodes,
      dependencies.trees,
    )
    debug "sortedNodes", sorted = sortedListOfDependencies

    # Step 1: Add open dependents with their stash paths so nimsuggest
    # recompiles them against their in-memory (possibly unsaved) content. 
    # let checkDependents = config.checkDependentsOnChange

    let allChanged = false
    let checkDependents = false

      # The first command.
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
      if fasUri in openFiles:
        let changedQuery = NimsuggestQuery[LspFilePosition](
          id: 0,
          kind: NimsuggestQueryKind.CHECK_FILE,
          isDependency: true,
          saved: false,
          uri: fasUri,
          dirtyFile:  uriToStashFilePath(storageDir, fasUri),
          responseFuture: newFuture[seq[Suggest]]("checkFile"),
        )
        result.add(changedQuery)

      else:
        let checkedQuery = NimsuggestQuery[LspFilePosition](
          id: 0,
          kind: NimsuggestQueryKind.CHECK_FILE,
          isDependency: true,
          saved: false,
          uri: fasUri,
          dirtyFile: FilePathAbs(""),
          responseFuture: newFuture[seq[Suggest]]("checkFile"),
        )
        result.add(checkedQuery)

    # for f in sortedListOfDependencies:
    #   let fasUri = toUri(f)
    #   if fasUri in openFiles:
    #     let changedQuery = NimsuggestQuery[LspFilePosition](
    #       id: 0,
    #       kind: NimsuggestQueryKind.CHECK_FILE,
    #       isDependency: true,
    #       saved: false,
    #       uri: fasUri,
    #       dirtyFile: uriToStashFilePath(storageDir, fasUri),
    #       responseFuture: newFuture[seq[Suggest]]("checkFile"),
    #     )
    #     result.add(changedQuery)

    # The first command.
    # let endCheck = NimsuggestQuery[LspFilePosition](
    #   id: 0,
    #   kind: NimsuggestQueryKind.CHECK_PROJECT,
    #   # isDependency: true,
    #   # saved: false,
    #   uri: query.uri,
    #   dirtyFile: query.dirtyFile,
    #   responseFuture: newFuture[seq[Suggest]]("checkFile"),
    # )
    # result.add(endCheck)


  # Step 3: Self-check the changed file (added last → runs first).
  # Pass query.dirtyFile so nimsuggest reads from the stash, not disk,
  # preserving unsaved in-memory content during recompilation.
  
  # THE LAST COMMAND
  # let checkQuery = NimsuggestQuery[LspFilePosition](
  #   id: 0,
  #   kind: NimsuggestQueryKind.CHECK_FILE,
  #   isDependency: true,
  #   saved: false,
  #   uri: query.uri,
  #   dirtyFile: query.dirtyFile,
  #   responseFuture: newFuture[seq[Suggest]]("checkFile"),
  # )
  # result.add(checkQuery)

# CLAUDE.md — nimlangserver fork

Fork of [nimlangserver](https://github.com/nim-lang/langserver). Ground-up rewrite in `src/` with a proper module hierarchy.

## Build & test

```sh
cd langserver && nimble build          # outputs to bin/nimtortoise (path VS Code uses)
cd langserver && nim c --path:. tests/<file>.nim        # compile-check one test
cd langserver && nim c -r --path:. tests/<file>.nim 2>&1 | tee /tmp/test_output.txt
```

**Never** use `nim c src/nimtortoise.nim` — outputs to `src/nimtortoise`, not picked up by VS Code.
**Never** run `tests/all.nim` — port-reuse races and FD exhaustion make failures non-isolatable.

Config: `tests/config.nims`. Fixtures: `tests/projects/`.

## Design philosophy

**Correctness over speed.** All file ops and nimsuggest queries flow through `langserverQueue` in FIFO order. Waits inside the drain coroutine are **intentional**:
- `didChange` stash write must complete before hover/inlay-hint — or nimsuggest sees stale content
- Nimsuggest slot must be fully spawned (`await execSpawn`) before queries reach it
- `DID_OPEN` waits for `lsInitialized` so files route to pre-spawned project slots

## Test infrastructure

- **`tests/lspsocketclient.nim`** — `LspSocketClient`, `startServer`, `notify`, `call`, `connect`, `waitForNotification`, `waitForNotificationMessage`, `setWorkspaceConfig`, `registerNotification`, `positionParams`, `initialize`, `stopServer`
- **`tests/client_utils.nim`** — path helpers (`simpleProjectFile`, `pkgaProjectFile`…), `doInitialize`, `waitForNsInit`, `waitForInstanceCount`, `sendHover`, `sendCompletion`, `sendDidChange`, `sendDidSave`, `sendDidRename`, `generateSimpleNimblePaths`, `generateMonorepoNimblePaths`, `createDidOpenParams`
- **`tests/fixhelpers.nim`** — re-export of both above + `sendDidOpen`, `startServer(rootRelPath)` compat overload
- **`tests/tbughelpers.nim`** — `startCombinedServer(maxNs)`, `combinedMapping()`, path constants: `simpleRel`, `widgetRel`, `orphanRel`, `orphan2Rel`, `pkgbRel`, `pkgaRel`, `aorphanRel`

**Config sequencing**: call `client.setWorkspaceConfig(...)` **before** `doInitialize` + `notify("initialized")`.

## Directory structure

```
forest/src/
  forest.nim                         # re-exports all submodules
  forest/
    forest_types.nim                 # Forest, NimbleDumpInfo, NimDumpInfo, NimInfo, DependencyGraph
    forest_utils.nim                 # getAllFiles, debugStr, toJsonHook
    init_forest.nim                  # initForest(rootPath) → Future[Forest]
    dependency_tree.nim              # initDependencyGraph, extractImports, resolveImport, visit
    dependency_tree_utils.nim        # isDependency, isDependent, findIntermediatePath
    nimble_dump.nim                  # initNimbleInfo
    nim_dump.nim                     # getNimDumpInfoForEntryPoints
  resources/
    resource_types.nim               # FileUri, FilePathAbs, FilePathRel, DirPathAbs, DirPathRel
    resource_utils.nim               # $, ==, hash, %, toUri, toFilePathAbs, toDirPathAbs,
                                     #   / (path join), parentDir, filename, stem, ext,
                                     #   isInside, toAbs, toRel, withExt, asFilePathAbs, asDirPathAbs

api/src/
  api.nim                            # re-exports api_types + api_utils
  api_types.nim                      # LspExtensionCapability, NimsuggestCapability, NimsuggestStatus,
                                     #   NimTortoiseServerStatus, ExtensionCommandRequest/Response,
                                     #   NimbleTask, ProjectError, PerformanceSetting, MessageType
  api_utils.nim                      # toExtensionCommandRequest, toJsonHook, getAllServerCapabilities

langserver/src/
  nimtortoise.nim                    # entry point; main(), registerLspRoutes()
  protocol/
    types.nim                        # re-exports all protocol submodules
    primitives.nim                   # JsonString and low-level protocol primitives
    lsp_basic.nim                    # Position, Range, Location, TextEdit…
    lsp_capabilities.nim             # client/server capability types
    lsp_diagnostics.nim              # Diagnostic, DiagnosticSeverity, PublishDiagnosticsParams
    lsp_protocol.nim                 # core protocol message types
    enums.nim                        # LSP/MCP enums
    mcp.nim                          # MCP protocol types
  configurations/
    configuration_types.nim          # NlsConfig, LanguageServerConfigurations (currentConfig + configReady)
    configuration_utils.nim          # isDifferentFrom; equality helpers
    configurations.nim               # parseWorkspaceConfiguration, nlsConfigFromJson
    init_configurations.nim          # initDefaultNlsConfig, parseDidChangeConfiguration
    constants.nim                    # LSP version, timeout, MAX_CRASH_RETRIES
  langserver/
    langserver.nim                   # re-export hub
    langserver_types.nim             # LanguageServer, LanguageServerCapabilities,
                                     #   LanguageServerFiles, LanguageServerMessaging,
                                     #   LanguageServerTransport, CommandLineParams,
                                     #   PendingRequest, LspDispatchItem
    init_langserver.nim              # initLanguageServer, tick, initialize, initialized,
                                     #   initNimsuggestInstances, stopNimsuggestProcesses,
                                     #   getIntendedProject, getWorkingDir
    langserver_messaging.nim         # showMessage, progress, workDoneProgressCreate,
                                     #   getLspStatus, sendStatusChanged, addProjectFileToPendingRequest
    langserver_utils.nim             # URI handling, UTF-8/UTF-16 conversion, stash paths
    transports.nim                   # RPC transport layer (stdio / socket)
    dispatcher.nim                   # processLangserverQueue — drains ls.langserverQueue in FIFO
    dispatcher_did_open.nim          # DID_OPEN branch: slot lookup, spawn, consolidation
    dispatcher_did_change.nim        # DID_CHANGE branch: stash write, diagnostic scheduling
    dispatcher_did_save.nim          # DID_SAVE branch
    dispatcher_did_close.nim         # DID_CLOSE branch
    dispatcher_did_rename.nim        # DID_RENAME branch
    dispatcher_did_delete.nim        # DID_DELETE branch
    dispatcher_utils.nim             # isKnownByANimsuggestSlot, addFileToOpenFiles,
                                     #   queryFile, nimsuggestSlotToEvict
    capability_configs.nim           # usePullConfigurationModel, supportsConfigurationRequest
    query_types.nim                  # LangserverQuery (NIMSUGGEST | FILE_ACCESS | RESTART),
                                     #   FileAccessQuery, FileAccessQueryKind
  handlers/
    handlers.nim                     # re-exports all handler submodules
    handler_utils.nim                # wrapRpc, addRpcToCancellable
    notification_files.nim           # didOpen, didChange, didSave, didClose,
                                     #   didRenameFiles, didDeleteFiles, didChangeConfiguration
    notification_process.nim         # initialized, cancelRequest, setTrace
    queries_file_access.nim          # file-level query helpers
    queries_nimsuggest.nim           # nimsuggest query helpers
    request_extension.nim            # extension/* handlers; workspace/executeCommand
    request_process.nim              # initialize, shutdown, exit
    request_text_document.nim        # textDocument/* handlers
    request_workspace.nim            # workspace/* handlers
  nimsuggest/
    nimsuggest.nim                   # re-export hub
    nimsuggest_types.nim             # NimsuggestQuery, NimsuggestSlot, NimsuggestPool,
                                     #   NimsuggestQueryKind, LspFilePosition, SlotState,
                                     #   NlsFileInfo, LanguageServerFiles
    nimsuggest_slots.nim             # execSpawn, execStop, restartSlot; slot state machine
    nimsuggest_process.nim           # processNimsuggestQueries, runNimsuggestQuery; TCP dispatch
    nimsuggest_utils.nim             # mailboxHasQueryOfKind, mailboxHasChangedQuery…
    nimsuggest_dependencies.nim      # dependency tracking for nimsuggest instances
    diagnostics.nim                  # toLspFilePosition; nimsuggest→LSP diagnostic conversion
    suggestapi.nim                   # createNimsuggest; raw TCP protocol (sug/def/hover/chk…)
    suggestapi_types.nim             # NimSuggest, Suggest, NimsuggestSettings, NimsuggestSpawnInfo
    suggestapi_queries.nim           # query construction helpers
    suggestapi_utils.nim             # Suggest parsing/formatting utilities
  nimble/
    nimble.nim                       # getNimbleEntryPoints, getNimbleTasks, runNimbleTask
    nimble_types.nim                 # NimbleDumpInfo (langserver-side)
    nimble_utils.nim                 # getNimblePaths, nimble path resolution helpers
    nimscript_utils.nim              # nimscript helpers
    nimscriptapi.nim                 # nimscript API template
  nim_compiler/
    nim_expand.nim                   # macro/ARC expansion
  nph/
    formatting.nim                   # nph-based document formatting
  utils/
    utils.nim                        # general utilities
    asyncprocmonitor.nim             # hookAsyncProcMonitor
    process_utils.nim                # withTimeout, shutdownChildProcess
    type_mismatch_format.nim         # formatting for type mismatch errors
```

**Import convention**: relative paths from each file's own directory.
**Path setup** (`langserver/config.nims`): includes `nimble.paths`, `../forest/src`, `../api/src`.

## Path types (from `forest/src/resources/resource_types.nim`)

All `distinct string` — never use raw `string` for paths or URIs:

| Type | Meaning |
|---|---|
| `FileUri` | `file://` URI |
| `FilePathAbs` | absolute path to a file |
| `FilePathRel` | relative path to a file |
| `DirPathAbs` | absolute path to a directory |
| `DirPathRel` | relative path to a directory |

Key procs: `toUri`, `toFilePathAbs`, `toDirPathAbs`, `/` (path join), `isInside`, `toAbs`, `toRel`, `parentDir`, `filename`, `stem`, `ext`, `withExt`, `asFilePathAbs`, `asDirPathAbs`.

## Key data structures

### `LanguageServer` (`src/langserver/langserver_types.nim`)

```nim
LanguageServer* = ref object
  capabilities*:    LanguageServerCapabilities    # lspClientCapabilities + lspServerCapabilities + extensionCapabilities
  configurations*:  LanguageServerConfigurations  # currentConfig + configReady AsyncEvent
  transport*:       LanguageServerTransport        # stdio or socket
  dependencies*:    Forest                         # dep graph + nimble/nim info
  files*:           LanguageServerFiles            # openFiles TableRef, storageDir, rootPath
  pool*:            NimsuggestPool                 # slot table + injected procs
  messaging*:       LanguageServerMessaging        # pendingRequests, responseMap, projectErrors
  lspQueue*:        AsyncQueue[LspDispatchItem]
  langserverQueue*: AsyncQueue[LangserverQuery]    # FIFO queue for all file + nimsuggest work
  notify*:          NotifyAction
  call*:            CallAction
  onExit*:          OnExitCallback
  isShutdown*:      bool
  lsInitialized*:   Future[void]                  # completed after initNimsuggestInstances
  cmdLineClientProcessId*: Option[int]
```

### `NimsuggestSlot` (`src/nimsuggest/nimsuggest_types.nim`)

```nim
NimsuggestSlot* = ref object
  state*:         SlotState                           # STOPPED|SPAWNING|READY|STOPPING|CRASHED
  spawnInfo*:     NimsuggestSpawnInfo                 # entryPoint, workingDir, nimbleFile, paths, extraArgs
  ownedUris*:     HashSet[FileUri]
  crashedUris*:   HashSet[FileUri]
  ns*:            Future[NimSuggest]
  spawnProcess*:  Option[AsyncProcessRef]
  queryMailbox*:  AsyncQueue[NimsuggestQuery[LspFilePosition]]
```

Note: `crashCount` field has been **removed**. Slot lifecycle managed entirely by `state`.

### Extension API

Nimsuggest restart via `workspace/executeCommand`:
```json
{"command": "nimsuggestRestart", "arguments": {"slot": "/abs/path/to/entry.nim"}}
```
Server endpoints: `extension/status`, `extension/capabilities`, `extension/restart`, `extension/listTasks`, `extension/runTask`, `extension/macroExpand` (stub).

## Routing layer

```
LSP handler
  → queryFile(ls, uri, kind)            # enqueue NimsuggestQuery on slot.queryMailbox
  → processNimsuggestQueries drains it
      → openTCP to slot.ns.port
      → send command, read lines until ".\n"
      → if empty: markFailed (CRASHED)
      → else: parse Suggest seq
  → map Suggest → LSP types → respond
```

`langserverQueue` → `processLangserverQueue`:
- `NIMSUGGEST` → `slot.queryMailbox.addLastNoWait(q)` (serializes stash writes before queries)
- `FILE_ACCESS` → executes inline (DID_OPEN, DID_CHANGE, DID_SAVE, DID_CLOSE, etc.)
- `RESTART` → server-level restart

## Two-table state model

```
ls.files.openFiles       TableRef[FileUri, NlsFileInfo]  ← LSP ground truth
slot.ownedUris           HashSet[FileUri]                 ← per-slot subset
```

Every `openFiles` insertion/deletion must mirror to the slot via `slot.assignUri(uri)` / `slot.unassignUri(uri)`.

## Stash (dirtyfile) mechanism

1. `didOpen` → stash written immediately (`storageDir/(sha1(uri) & ".nim")`)
2. `didChange` → stash overwritten; `fileInfo.lastChanged` updated
3. At dispatch time `processLangserverQueue` sets `q.dirtyFile`: `""` if `saved=true`, else stash path
4. `didSave` → enqueues `CHANGED(saved=true)` then `CHECK_FILE`

## Async / sync rule

`{.async.}` only if the proc has at least one `await`. Sync procs are implicitly atomic under Chronos.

**Infinite loops**: use `while true` + `await sleepAsync(...)`, never tail recursion (`await self()`) — each tail call leaks a Future → ORC heap corruption.

## Invariants

1. **Snapshot `slot.ownedUris` before async iteration** — `for uri in slot.ownedUris.toSeq:`
2. **Never cancel `ls.configurations.configReady`** — shared `AsyncEvent`; use polling loops instead
3. **`var p: AsyncProcessRef` in try blocks: check `if p != nil:` in `finally`** — nil deref → SIGSEGV
4. **`projectErrors` shows commands that failed *after* the crash** — find root cause by searching backwards for last `DBG Started...` with no matching `DBG CPU Time`
5. **Stash path uses SHA-1** (`uriStorageLocation` in `langserver_utils.nim`) — do not revert to `hash(uri).toHex`
6. **Guard `fileInfo.slot` before use in didClose/didSave** — slot may be nil if didOpen hasn't completed
7. **Path types are distinct strings** — never pass raw `string` where a typed path/URI is expected; cast explicitly

## Known issues

- **`extension/macroExpand`** — stub, not implemented
- **Per-file diagnostics only on save** — `CHECK_FILE` only enqueued after a `CHANGED` command completes

## Environment

- **Two nimble binaries**: `~/.nimble/bin/nimble` (v0.22.2, correct) vs `/usr/local/bin/nimble` (v0.18.2, Homebrew). Dock-launched VS Code gets only `/usr/bin:/bin:/usr/sbin:/sbin` — wrong binary. Terminal launch inherits full PATH.
- **`nimble.paths` is gitignored** — run `nimble setup` after cloning
- **Cold-compilation gap ~11s** with correct nimble binary; subsequent requests < 1s (NimCache)

## Debugging

Use `debug "..."` via `chronicles`. VS Code LSP trace log (`"nim.logNimsuggest": true`) captures protocol messages and debug output. For crashes: check `projectErrors` in `extension/status`, then search backwards for last `DBG Started...` with no matching `DBG CPU Time`.

# CLAUDE.md — nimlangserver fork context

Fork of [nimlangserver](https://github.com/nim-lang/langserver). Ground-up rewrite in `src/` with a proper module hierarchy.

## Design philosophy

**Correctness over speed.** All file operations and nimsuggest queries flow through a single FIFO queue (`langserverQueue`) in arrival order. Waiting inside the drain coroutine is **intentional**:

- A `didChange` stash write must complete before any hover/inlay-hint query — or nimsuggest sees stale content.
- A nimsuggest slot must be fully spawned (`await execSpawn`) before queries reach it.
- `DID_OPEN` waits for `lsInitialized` so files route to pre-spawned project slots.

These waits freeze later queue items for their duration. That is correct: LSP messages are ordered.

---

## Build & test commands

```sh
# Build (outputs to bin/nimtortoise — the path VS Code uses):
cd langserver && nimble build

# Compile-check one test:
cd langserver && nim c --path:. tests/<file>.nim

# Run ONE test file (never run all.nim directly):
cd langserver && nim c -r --path:. tests/<file>.nim 2>&1 | tee /tmp/test_output.txt
```

**IMPORTANT**: Always use `nimble build` to build the language server. `nim c src/nimtortoise.nim` outputs to `src/nimtortoise` and is NOT picked up by VS Code, which uses `bin/nimtortoise`.

**DO NOT run `tests/all.nim`** — port-reuse races and FD exhaustion make failures hard to isolate.

Config: `tests/config.nims`. Fixtures: `tests/projects/`.

---

## Test file status (as of 2026-08-26)

| File | Tests | Status | Notes |
|---|---|---|---|
| `tsuggestapi.nim` | 8 | ✓ all pass | |
| `tmisc.nim` | 1 | ✓ pass | |
| `thover.nim` | 1 | ✓ pass | |
| `tnimlangserver.nim` | 14 | ✓ all pass | |
| `tmonorepo.nim` | 4 | ✓ all pass | |
| `tmonorepo2.nim` | 3 | ✓ all pass | |
| `tknownbug3.nim` | 1 | ✓ pass | Was "EXPECTED FAIL" — bug appears fixed |
| `tmonorepo3.nim` | 1 | ✓ pass | |
| `tmaxlimits.nim` | 4 | ✓ all pass | |
| `textensions.nim` | 1 | ✓ pass | |
| `tstability.nim` | 13 | not verified | Slow (multi-spawn), may pass |
| `tdependencies.nim` | 6 | not verified | Slow (15s diagnostic waits), may pass |

### Test infrastructure

- **`tests/lspsocketclient.nim`** — `LspSocketClient`, `startServer()`, `notify`, `call`, `connect`, `waitForNotification`, `waitForNotificationMessage`, `setWorkspaceConfig`, `registerNotification`, `positionParams`, `initialize`, `stopServer`.
- **`tests/client_utils.nim`** — project-file path helpers (`simpleProjectFile`, `pkgaProjectFile`, etc.), `doInitialize`, `waitForNsInit`, `waitForInstanceCount`, `sendHover`, `sendCompletion`, `sendDidChange`, `sendDidSave`, `sendDidRename`, `generateSimpleNimblePaths`, `generateMonorepoNimblePaths`, `createDidOpenParams`.
- **`tests/fixhelpers.nim`** — thin re-export of both above + `sendDidOpen`, `startServer(rootRelPath)` compat overload.
- **`tests/tbughelpers.nim`** — `startCombinedServer(maxNs)`, `combinedMapping()`, path constants: `simpleRel`, `widgetRel`, `orphanRel`, `orphan2Rel`, `pkgbRel`, `pkgaRel`, `aorphanRel`.

**Config sequencing**: call `client.setWorkspaceConfig(%*[{...}])` **before** `doInitialize` + `notify("initialized")`.

---

## Directory structure

```
forest/                              # Separate package — dependency graph library
  src/
    forest.nim                       # Re-exports all submodules
    forest/
      forest_types.nim               # Forest, NimbleDumpInfo, NimDumpInfo, NimInfo, DependencyGraph
      forest_utils.nim               # getAllFiles, debugStr, toJsonHook
      init_forest.nim                # initForest(rootPath) → Future[Forest]
      dependency_tree.nim            # initDependencyGraph, extractImports, resolveImport, visit
      dependency_tree_utils.nim      # isDependency, isDependent, findIntermediatePath
      nimble_dump.nim                # initNimbleInfo
      nim_dump.nim                   # getNimDumpInfoForEntryPoints
    resources/
      resource_types.nim             # FileUri, FilePathAbs, FilePathRel, DirPathAbs, DirPathRel
      resource_utils.nim             # $, ==, hash, %, toUri, toFilePathAbs, toDirPathAbs,
                                     #   `/` path join, parentDir, filename, stem, ext,
                                     #   isInside, toAbs, toRel, withExt, asFilePathAbs, asDirPathAbs

api/                                 # Separate package — shared API types between server and VS Code extension
  src/
    api.nim                          # Re-exports api_types + api_utils
    api_types.nim                    # LspExtensionCapability, NimsuggestCapability, NimsuggestStatus,
                                     #   NimTortoiseServerStatus, ExtensionCommandRequest/Response,
                                     #   NimbleTask, ProjectError, PerformanceSetting, MessageType
    api_utils.nim                    # toExtensionCommandRequest, toJsonHook, getAllServerCapabilities

langserver/src/
├── nimtortoise.nim                  # Entry point; main(), registerLspRoutes()
├── protocol/
│   ├── types.nim                    # Re-exports all protocol submodules
│   ├── primitives.nim               # JsonString and low-level protocol primitives
│   ├── lsp_basic.nim                # Basic LSP types (Position, Range, Location, TextEdit…)
│   ├── lsp_capabilities.nim         # Client/server capability types
│   ├── lsp_diagnostics.nim          # Diagnostic, DiagnosticSeverity, PublishDiagnosticsParams
│   ├── lsp_protocol.nim             # Core protocol message types
│   ├── enums.nim                    # LSP/MCP enums
│   ├── extensions.nim               # nimtortoise extension protocol types
│   └── mcp.nim                      # MCP protocol types
├── configurations/
│   ├── configuration_types.nim      # NlsConfig, LanguageServerConfigurations (currentConfig + configReady)
│   ├── configuration_utils.nim      # isDifferentFrom; equality helpers
│   ├── configurations.nim           # parseWorkspaceConfiguration, nlsConfigFromJson
│   ├── init_configurations.nim      # initDefaultNlsConfig, parseDidChangeConfiguration
│   └── constants.nim                # LSP version, timeout, MAX_CRASH_RETRIES
├── langserver/
│   ├── langserver.nim               # Re-export hub for langserver submodules
│   ├── langserver_types.nim         # LanguageServer, LanguageServerCapabilities,
│   │                                #   LanguageServerFiles (in nimsuggest_types),
│   │                                #   LanguageServerMessaging, LanguageServerTransport,
│   │                                #   CommandLineParams, PendingRequest, LspDispatchItem
│   ├── init_langserver.nim          # initLanguageServer, tick, initialize, initialized,
│   │                                #   initNimsuggestInstances, stopNimsuggestProcesses,
│   │                                #   getIntendedProject, getWorkingDir
│   ├── langserver_messaging.nim     # showMessage, progress, workDoneProgressCreate,
│   │                                #   getLspStatus, sendStatusChanged,
│   │                                #   addProjectFileToPendingRequest
│   ├── langserver_utils.nim         # URI handling, UTF-8/UTF-16 conversion, stash paths
│   ├── transports.nim               # RPC transport layer (stdio / socket)
│   ├── dispatcher.nim               # processLangserverQueue — drains ls.langserverQueue in FIFO
│   ├── dispatcher_did_open.nim      # DID_OPEN branch: slot lookup, spawn, consolidation
│   ├── dispatcher_did_change.nim    # DID_CHANGE branch: stash write, diagnostic scheduling
│   ├── dispatcher_utils.nim         # isKnownByANimsuggestSlot, addFileToOpenFiles,
│   │                                #   queryFile, nimsuggestSlotToEvict
│   ├── capability_configs.nim       # usePullConfigurationModel, supportsConfigurationRequest
│   └── query_types.nim              # LangserverQuery (NIMSUGGEST | FILE_ACCESS | RESTART),
│                                    #   FileAccessQuery, FileAccessQueryKind
├── handlers/
│   ├── handlers.nim                 # Re-exports all handler submodules
│   ├── handler_utils.nim            # wrapRpc, addRpcToCancellable
│   ├── notification_files.nim       # didOpen, didChange, didSave, didClose,
│   │                                #   didRenameFiles, didDeleteFiles, didChangeConfiguration
│   ├── notification_process.nim     # initialized, cancelRequest, setTrace
│   ├── queries_file_access.nim      # File-level query helpers
│   ├── queries_nimsuggest.nim       # Nimsuggest query helpers
│   ├── request_extension.nim        # extension/* handlers; also workspace/executeCommand
│   ├── request_process.nim          # initialize, shutdown, exit
│   ├── request_text_document.nim    # textDocument/* handlers
│   └── request_workspace.nim        # workspace/* handlers
├── nimsuggest/
│   ├── nimsuggest.nim               # Re-export hub for nimsuggest submodules
│   ├── nimsuggest_types.nim         # NimsuggestQuery, NimsuggestSlot, NimsuggestPool,
│   │                                #   NimsuggestQueryKind, LspFilePosition, SlotState,
│   │                                #   NlsFileInfo, LanguageServerFiles
│   ├── nimsuggest_slots.nim         # execSpawn, execStop, restartSlot; slot state machine
│   ├── nimsuggest_process.nim       # processNimsuggestQueries, runNimsuggestQuery; TCP dispatch
│   ├── nimsuggest_utils.nim         # mailboxHasQueryOfKind, mailboxHasChangedQuery…
│   ├── diagnostics.nim              # toLspFilePosition; nimsuggest→LSP diagnostic conversion
│   ├── suggestapi.nim               # createNimsuggest; raw TCP protocol (sug/def/hover/chk…)
│   ├── suggestapi_types.nim         # NimSuggest, Suggest, NimSuggestCapability,
│   │                                #   NimsuggestSettings, NimsuggestSpawnInfo
│   ├── suggestapi_queries.nim       # Query construction helpers
│   └── suggestapi_utils.nim         # Suggest parsing/formatting utilities
├── nimble/
│   ├── nimble.nim                   # getNimbleEntryPoints, getNimbleTasks, runNimbleTask
│   ├── nimble_types.nim             # NimbleDumpInfo (langserver-side)
│   ├── nimble_utils.nim             # getNimblePaths, nimble path resolution helpers
│   ├── nimscript_utils.nim          # nimscript helpers
│   └── nimscriptapi.nim             # nimscript API template
├── nim_compiler/
│   └── nim_expand.nim               # macro/ARC expansion
├── nph/
│   └── formatting.nim               # nph-based document formatting
└── utils/
    ├── utils.nim                    # General utilities
    ├── asyncprocmonitor.nim         # hookAsyncProcMonitor
    ├── process_utils.nim            # Process utilities (withTimeout, shutdownChildProcess)
    └── type_mismatch_format.nim     # Formatting for type mismatch errors
```

**Import path convention**: relative paths from each file's own directory.

**Path setup** (`langserver/config.nims`): includes `nimble.paths`, `../forest/src`, `../api/src`. Both `forest` and `api` are separate packages in the repo root and must be on the path.

---

## The `forest` module

`forest` is a separate Nim package at `<repo root>/forest/`. It is imported as `import forest` throughout `langserver/src/`. It provides:

### Path types (all `distinct string`, from `forest/src/resources/resource_types.nim`)

| Type | Meaning |
|---|---|
| `FileUri` | `file://` URI (e.g. `file:///Users/foo/bar.nim`) |
| `FilePathAbs` | Absolute filesystem path to a file |
| `FilePathRel` | Relative filesystem path to a file |
| `DirPathAbs` | Absolute filesystem path to a directory |
| `DirPathRel` | Relative filesystem path to a directory |

These are the canonical types for all paths in the langserver. Always use them; never use raw `string` for paths or URIs.

Key utility procs (from `resource_utils.nim`): `toUri(FilePathAbs) → FileUri`, `toFilePathAbs(FileUri) → FilePathAbs`, `toDirPathAbs(FileUri) → DirPathAbs`, `/` operator (path joining, type-safe), `isInside(file, dir)`, `toAbs`, `toRel`, `parentDir`, `filename`, `stem`, `ext`, `withExt`, `asFilePathAbs`/`asDirPathAbs` (reinterpretation casts).

### Forest types (from `forest/src/forest/forest_types.nim`)

```nim
Forest* = object
  root*:   DirPathAbs
  nim*:    NimInfo                            # version + nimExe
  nimble*: Table[FilePathAbs, NimbleDumpInfo] # per-.nimble-file dump
  paths*:  Table[FilePathAbs, seq[DirPathAbs]] # lib paths per entry point
  trees*:  Table[FilePathAbs, seq[FilePathAbs]] # dep graph: entry → all deps
```

---

## Key data structures

### `LanguageServer` (in `src/langserver/langserver_types.nim`)

```nim
LanguageServer* = ref object
  capabilities*:    LanguageServerCapabilities    # lspClientCapabilities + lspServerCapabilities + extensionCapabilities
  configurations*:  LanguageServerConfigurations  # currentConfig + configReady AsyncEvent
  transport*:       LanguageServerTransport        # stdio or socket
  dependencies*:    Forest                         # dep graph + nimble/nim info; built in initLanguageServer
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

### `NimsuggestSlot` (in `src/nimsuggest/nimsuggest_types.nim`)

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

Note: `crashCount` field has been **removed** from `NimsuggestSlot`. Slot lifecycle is managed entirely by `state`.

### Extension API

Nimsuggest restart is via `workspace/executeCommand`:
```json
{"command": "nimsuggestRestart", "arguments": {"slot": "/abs/path/to/entry.nim"}}
```
Server endpoints: `extension/status`, `extension/capabilities`, `extension/restart` (server restart), `extension/listTasks`, `extension/runTask`, `extension/macroExpand`. Nimsuggest-specific operations go through `workspace/executeCommand`.

---

## Module boundary intent

- `forest/` — path types, dep graph, nimble/nim dump; no langserver dependency.
- `api/` — shared types between server and VS Code extension (`LspExtensionCapability`, `ExtensionCommandRequest/Response`, etc.); no langserver dependency.
- `configurations/` — `NlsConfig` + parsing; no LS dependency.
- `nimsuggest/nimsuggest_types.nim` — all nimsuggest + slot + pool types; also `NlsFileInfo`, `LanguageServerFiles`.
- `nimsuggest/nimsuggest_slots.nim` — `execSpawn`, `execStop`, `restartSlot`; slot state machine.
- `nimsuggest/nimsuggest_process.nim` — `processNimsuggestQueries`, `runNimsuggestQuery`; TCP dispatch.
- `nimsuggest/nimsuggest_utils.nim` — `mailboxHasQueryOfKind`, `mailboxHasChangedQueryForSameUriAnyOtherUri`.
- `nimsuggest/suggestapi.nim` — `createNimsuggest`, raw TCP protocol.
- `langserver/init_langserver.nim` — `initLanguageServer`, `tick`, `initialize`, `initialized`, `initNimsuggestInstances`.
- `langserver/dispatcher.nim` — `processLangserverQueue` (FIFO queue drain).
- `handlers/request_extension.nim` — all `extension/*` handlers + `workspace/executeCommand`.
- `handlers/` — LSP request/notification handlers; enqueue onto `ls.langserverQueue`.

---

## The routing layer

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

---

## The two-table state model

```
ls.files.openFiles       TableRef[FileUri, NlsFileInfo]  ← LSP ground truth
slot.ownedUris           HashSet[FileUri]                 ← per-slot subset
```

Every `openFiles` insertion/deletion must be mirrored to the slot via `slot.assignUri(uri)` / `slot.unassignUri(uri)`.

**Deadly pattern**: iterating `slot.ownedUris` with any `await` inside. Always snapshot first: `for uri in slot.ownedUris.toSeq:`.

---

## The stash (dirtyfile) mechanism

1. `didOpen` → stash written immediately (`storageDir/(sha1(uri) & ".nim")`).
2. `didChange` → stash overwritten; `fileInfo.lastChanged` updated.
3. At dispatch time `processLangserverQueue` sets `q.dirtyFile`: `""` if `saved=true`, else the stash path.
4. `didSave` → enqueues `CHANGED(saved=true)` then `CHECK_FILE`.

---

## Async vs sync rule

`{.async.}` only if the proc has at least one `await`. Sync procs are implicitly atomic under Chronos's cooperative scheduler.

**Infinite loops**: must use `while true` + `await sleepAsync(...)`, never tail recursion (`await self()`). Each tail call creates a Future that is never freed → ORC heap corruption.

---

## Consolidated invariants

1. **Snapshot `slot.ownedUris` before async iteration** — use `for uri in slot.ownedUris.toSeq:`.
2. **Never cancel `ls.configurations.configReady`** — shared `AsyncEvent`; use polling loops instead.
3. **`var p: AsyncProcessRef` in try blocks must check `if p != nil:` in `finally`** — nil deref → SIGSEGV.
4. **`projectErrors` shows commands that failed *after* the crash** — find triggering command by searching backwards for last `DBG Started...` with no matching `DBG CPU Time`.
5. **Stash path uses SHA-1** (`uriStorageLocation` in `langserver_utils.nim`) — do not revert to `hash(uri).toHex`.
6. **Guard `fileInfo.slot` before use in didClose/didSave** — slot may be nil if didOpen hasn't completed slot assignment.
7. **Path types are distinct strings** — never pass raw `string` where `FilePathAbs`/`FileUri`/`DirPathAbs` is expected; cast explicitly.

---

## Known remaining issues

### P1 — Runtime bugs / broken tests
1. **Slot eviction mailbox drain race** (`dispatcher.nim`): futures completed with `@[]` while `processNimsuggestQueries` may be completing the same futures.

### P1 — Stub features
4. **`extension/macroExpand`** — stub.
5. **Per-file diagnostics only on save** — `CHECK_FILE` only enqueued after a `CHANGED` command completes.

---

## Key environmental facts

- **Two nimble binaries**: `~/.nimble/bin/nimble` (v0.22.2, correct) and `/usr/local/bin/nimble` (v0.18.2, Homebrew). Dock-launched VS Code gets only `/usr/bin:/bin:/usr/sbin:/sbin` — wrong binary. Terminal launch inherits full PATH.
- **`nimble.paths` is gitignored** — run `nimble setup` after cloning.
- **`nimble setup`** generates `nimble.paths` (`--noNimblePath` + `--path:` per dep). `config.nims` auto-includes it.
- **Cold-compilation gap ~11s** with correct nimble binary and `nimble.paths`. Subsequent requests < 1s (NimCache).

---

## Debugging

Add `debug "..."` via `chronicles`. The VS Code LSP trace log (`"nim.logNimsuggest": true`) captures both protocol messages and langserver debug output. When investigating crashes: check `projectErrors` in `extension/status` for post-crash failures, then search backwards for the last `DBG Started...` with no matching `DBG CPU Time` to find the triggering command.

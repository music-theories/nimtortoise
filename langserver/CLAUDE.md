# CLAUDE.md — nimlangserver fork context

Fork of [nimlangserver](https://github.com/nim-lang/langserver). The `dp-rewrite` branch is a ground-up rewrite in `src/` with a proper module hierarchy. Pre-rewrite analysis is in `langserver/rewrite_analysis/OLD_CLAUDE.md`.

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

# Run ONE test file (never run all.nim directly):
cd langserver && nim c --path:. -r tests/<file>.nim 2>&1 | tee /tmp/test_output.txt
```

**IMPORTANT**: Always use `nimble build` to build the language server. `nim c src/nimtortoise.nim` outputs to `src/nimtortoise` and is NOT picked up by VS Code, which uses `bin/nimtortoise`.

**DO NOT run `tests/all.nim`** — port-reuse races and FD exhaustion make failures hard to isolate.

Config: `tests/config.nims`. Fixtures: `tests/projects/`.

---

## Test file status (as of 2026-08-19)

| File | Tests | Status |
|---|---|---|
| `tsuggestapi.nim` | 8 | ✓ all pass |
| `tmaxlimits.nim` | 4 | ✓ all pass |
| `tknownbug3.nim` | 1 | ✓ all pass |
| `tstability.nim` | 13 | ✓ all pass |
| `tmonorepo.nim` | 4 | ✓ all pass |
| `tnimlangserver.nim` | 13 | ✓ all pass |
| `thover.nim` | 1 | ✓ all pass |
| `tmisc.nim` | 1 | ✓ all pass |
| `textensions.nim` | 1 | ✓ all pass |
| `tmonorepo2.nim` | 3 | ✓ all pass |
| `tmonorepo3.nim` | 1 | ✓ all pass |

### Test infrastructure

- **`tests/fixhelpers.nim`** — `LspSocketClient`, `startServer`, `doInitialize`, `waitForNsInit`, `sendDidOpen/Hover/Completion/Change/Save/Rename`. Fixture constants: `simpleRel`, `widgetRel`, `orphanRel`, `pkgbRel`, `pkgaRel`, etc.
- **`tests/lspsocketclient.nim`** — LSP client; `setWorkspaceConfig` to override `workspace/configuration` response.

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
│   │                                #   LanguageServerFiles, LanguageServerMessaging,
│   │                                #   LanguageServerTransport, CommandLineParams,
│   │                                #   PendingRequest, LspDispatchItem
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
│   └── query_types.nim              # LangserverQuery (NIMSUGGEST | FILE_ACCESS),
│                                    #   FileAccessQuery, FileAccessQueryKind
├── handlers/
│   ├── handlers.nim                 # Re-exports all handler submodules
│   ├── handler_utils.nim            # wrapRpc, addRpcToCancellable
│   ├── notification_files.nim       # didOpen, didChange, didSave, didClose,
│   │                                #   didRenameFiles, didDeleteFiles, didChangeConfiguration
│   ├── notification_process.nim     # initialized, cancelRequest, setTrace
│   ├── queries_file_access.nim      # File-level query helpers
│   ├── queries_nimsuggest.nim       # Nimsuggest query helpers
│   ├── request_extension.nim        # extension/* handlers
│   ├── request_process.nim          # initialize, shutdown, exit
│   ├── request_text_document.nim    # textDocument/* handlers
│   └── request_workspace.nim        # workspace/* handlers
├── nimsuggest/
│   ├── nimsuggest.nim               # Re-export hub for nimsuggest submodules
│   ├── nimsuggest_types.nim         # NimsuggestQuery, NimsuggestSlot, NimsuggestPool,
│   │                                #   NimsuggestQueryKind, LspFilePosition, SlotState,
│   │                                #   NlsFileInfo, LanguageServerFiles
│   ├── nimsuggest_slots.nim         # execSpawn, execStop; slot state machine
│   ├── nimsuggest_process.nim       # processNimsuggestQueries, runNimsuggestQuery; TCP dispatch
│   ├── nimsuggest_utils.nim         # mailboxHasQueryOfKind, mailboxHasChangedQuery…
│   ├── diagnostics.nim              # toLspFilePosition; nimsuggest→LSP diagnostic conversion
│   ├── suggestapi.nim               # createNimsuggest; raw TCP protocol (sug/def/hover/chk…)
│   ├── suggestapi_types.nim         # NimSuggest, Suggest, NimSuggestCapability,
│   │                                #   NimsuggestSettings, NimsuggestSpawnInfo
│   ├── suggestapi_queries.nim       # Query construction helpers
│   └── suggestapi_utils.nim         # Suggest parsing/formatting utilities
├── nimble/
│   ├── nimble.nim                   # getNimbleEntryPoints
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
    ├── process_utils.nim            # Process utilities
    └── type_mismatch_format.nim     # Formatting for type mismatch errors
```

**Import path convention**: relative paths from each file's own directory.

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

NimbleDumpInfo* = object
  name*:           string
  srcDir*:         DirPathRel
  bin*:            seq[FilePathRel]
  entryPoints*:    seq[FilePathRel]  # relative to nimble file dir
  testEntryPoint*: FilePathRel

DependencyGraph* = object
  graph*:  Table[FilePathAbs, seq[FilePathAbs]]  # file → direct imports (local only)
  states*: Table[FilePathAbs, VisitState]
  stack*:  seq[FilePathAbs]
  root*:   DirPathAbs
```

### Key procs

- `initForest(rootPath: DirPathAbs): Future[Forest]` — runs nimble dump + nim dump + dep graph construction; called once in `initLanguageServer`. Result stored in `ls.dependencies`.
- `isDependency(graph, rootFile, dependencyFile)` — is `dependencyFile` a transitive import of `rootFile`?
- `findIntermediatePath(graph, fromFile, toFile)` — intermediate files between two nodes (for cache invalidation).
- `extractImports(source: string): seq[string]` — parse-free import extractor; handles all common Nim import syntaxes.

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
  testRunProcess*:  Option[AsyncProcessRef]
```

`LanguageServerFiles`:
```nim
LanguageServerFiles* = object
  openFiles*:  TableRef[FileUri, NlsFileInfo]
  storageDir*: DirPathAbs
  rootPath*:   DirPathAbs
```

`dependencies` replaces the old `nimDumpCache` — nimble dump info is now in `ls.dependencies.nimble`.

### `NlsFileInfo` (in `src/nimsuggest/nimsuggest_types.nim`)

```nim
NlsFileInfo* = ref object of RootObj
  slot*:          NimsuggestSlot
  fingerTable*:   seq[seq[tuple[u16pos, offset: int]]]
  lastChanged*:   DateTime
  lastChecked*:   DateTime
  textDocument*:  TextDocumentItem
```

### `NimsuggestPool` and `NimsuggestSlot`

```nim
NimsuggestPool* = ref object
  slots*:         Table[FilePathAbs, NimsuggestSlot]  # entryPoint → slot
  crashedSlots*:  HashSet[FilePathAbs]                # failed entry points; cleared on save
  maxSlots*:      int
  nimsuggest*:    NimsuggestSettings                  # exePath, protocol, capabilities
  notifyProc*:    NotifyProc
  statusChangedProc*: StatusChangedProc

NimsuggestSlot* = ref object
  state*:         SlotState                           # STOPPED|SPAWNING|READY|STOPPING|CRASHED
  spawnInfo*:     NimsuggestSpawnInfo                 # entryPoint, workingDir, nimbleFile, paths, extraArgs
  ownedUris*:     HashSet[FileUri]
  crashedUris*:   HashSet[FileUri]
  ns*:            Future[NimSuggest]
  spawnProcess*:  Option[AsyncProcessRef]
  queryMailbox*:  AsyncQueue[NimsuggestQuery[LspFilePosition]]
  lastCmdTime*:   DateTime
  crashCount*:    int
```

`pool.slots` contains only canonical entries (no redirect aliases). Each slot has a `queryMailbox`; `processNimsuggestQueries` drains it and dispatches to TCP. `execSpawn` backs off exponentially between retries (`1_000 * (1 shl crashCount)` ms, capped at 30s).

---

## Module boundary intent

- `forest/` — path types, dep graph, nimble/nim dump; no langserver dependency.
- `configurations/` — `NlsConfig` + parsing; no LS dependency.
- `nimsuggest/nimsuggest_types.nim` — all nimsuggest + slot + pool types; also `NlsFileInfo`, `LanguageServerFiles`.
- `nimsuggest/nimsuggest_slots.nim` — `execSpawn`, `execStop`; slot state machine.
- `nimsuggest/nimsuggest_process.nim` — `processNimsuggestQueries`, `runNimsuggestQuery`; TCP dispatch. Two skip-rule groups: **background queries** (INLAY_HINTS, DOCUMENT_SYMBOLS) dropped if CHANGED pending or file edited within `FILE_CHECK_DELAY`; **position queries** dropped if a newer same-kind query queued for the same URI, or CHANGED pending.
- `nimsuggest/nimsuggest_utils.nim` — `mailboxHasQueryOfKind`, `mailboxHasChangedQueryForSameUriAnyOtherUri`.
- `nimsuggest/diagnostics.nim` — `toLspFilePosition`; nimsuggest→LSP coordinate conversion.
- `nimsuggest/suggestapi.nim` — `createNimsuggest`, raw TCP protocol.
- `langserver/init_langserver.nim` — `initLanguageServer`, `tick`, `initialize`, `initialized`, `initNimsuggestInstances`, `stopNimsuggestProcesses`, `getIntendedProject`.
- `langserver/langserver_messaging.nim` — `showMessage`, `progress`, `getLspStatus`, `sendStatusChanged`, `addProjectFileToPendingRequest`.
- `langserver/dispatcher.nim` — `processLangserverQueue` (FIFO queue drain).
- `langserver/dispatcher_did_open.nim` — DID_OPEN: slot lookup, `execSpawn`, consolidation.
- `langserver/dispatcher_did_change.nim` — DID_CHANGE: stash write, diagnostic scheduling.
- `langserver/dispatcher_utils.nim` — `isKnownByANimsuggestSlot`, `addFileToOpenFiles`, `queryFile`, `nimsuggestSlotToEvict`.
- `langserver/langserver.nim` — re-export hub only.
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

## Nimsuggest v4 unknown-file caveat

Always started with `--v4`. For files never imported into the project, `unknown` capability is non-functional: `graph.needsCompilation(fileIndex)` returns false for nil module → `recompilePartially` never runs → all commands return `length=0`. The langserver works around this by using the file itself as the entry point (fix #18).

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

### P1 — Runtime bugs
1. **Slot eviction mailbox drain race** (`dispatcher.nim`): futures completed with `@[]` while `processNimsuggestQueries` may be completing the same futures.

### P1 — Stub features
2. **`extension/macroExpand`** — stub.
3. **`extension/suggest` (restart action)** — stub.
4. **`extension/status` / `extension/capabilities`** — stubs; VS Code status bar empty.
5. **Per-file diagnostics only on save** — `CHECK_FILE` only enqueued after a `CHANGED` command completes.

---

## Key environmental facts

- **Two nimble binaries**: `~/.nimble/bin/nimble` (v0.22.2, correct) and `/usr/local/bin/nimble` (v0.18.2, Homebrew). Dock-launched VS Code gets only `/usr/bin:/bin:/usr/sbin:/sbin` — wrong binary. Terminal launch inherits full PATH.
- **`nimble.paths` is gitignored** — run `nimble setup` after cloning.
- **`nimble setup`** generates `nimble.paths` (`--noNimblePath` + `--path:` per dep). `config.nims` auto-includes it.
- **Cold-compilation gap ~11s** with correct nimble binary and `nimble.paths`. Subsequent requests < 1s (NimCache).

---

## Debugging

Add `debug "..."` via `chronicles`. The VS Code LSP trace log (`"nim.logNimsuggest": true`) captures both protocol messages and langserver debug output. When investigating crashes: check `projectErrors` in `extension/statusUpdate` for post-crash failures, then search backwards for the last `DBG Started...` with no matching `DBG CPU Time` to find the triggering command.

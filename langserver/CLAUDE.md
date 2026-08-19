# CLAUDE.md — nimlangserver fork context

This is a fork of [nimlangserver](https://github.com/nim-lang/langserver). The primary
goal is to fix severe startup performance problems caused by nimble's exponential SAT
solver running during VS Code startup. The `dp-rewrite` branch is a ground-up rewrite
in `src/` with a proper module hierarchy. Historical forensic analysis, per-fix narratives,
and pre-rewrite architecture notes are in `langserver/rewrite_analysis/OLD_CLAUDE.md`.

## Design philosophy

This rewrite **privileges correctness over speed**. The central mechanism is a single
FIFO queue (`langserverQueue`) through which all file operations and nimsuggest queries
flow in arrival order. Waiting and blocking inside the queue drain coroutine are
**intentional and necessary**:

- A `didChange` stash write must complete before any subsequent hover or inlay-hint
  query is dispatched, or nimsuggest sees stale content.
- A nimsuggest slot must be fully spawned (`await execSpawn`) before queries are
  dispatched to it, or the per-slot mailbox receives items it cannot serve.
- `DID_OPEN` waits for `lsInitialized` (config + nimble dump + entry-point spawns)
  so files are routed to pre-existing project slots rather than spawning their own.

These waits freeze processing of later items in the queue for their duration. That is
the correct behaviour: LSP messages are ordered, and the client can handle temporary
latency. Violating the ordering to gain speed introduces subtle state corruption that
is far harder to debug than slow responses.

---

## Branch structure

| Branch | PR target | Content |
|--------|-----------|---------|
| `fix/maxnimsuggestlimits-clean` | upstream `master` | Fixes 7–10 |
| `fix/nimsuggest-rename-recompile` | `fix/maxnimsuggestlimits-clean` | Fixes 11–21 |
| `dp-rewrite` | — | Ground-up rewrite in `src/` |

When `fix/maxnimsuggestlimits-clean` merges, rebase `fix/nimsuggest-rename-recompile`
onto upstream `master` and update its PR base.

---

## Key environmental facts

- **Two nimble binaries exist**: `~/.nimble/bin/nimble` (v0.22.2, correct) and
  `/usr/local/bin/nimble` (v0.18.2, Homebrew, older). When VS Code is **launched from
  the Dock**, PATH is limited (`/usr/bin:/bin:/usr/sbin:/sbin`), so the wrong binary is
  found via `{UsePath}`. Terminal launch inherits the full shell PATH and finds the right one.
- **The slow startup root cause** is nimble's SAT solver (`findMinimalFailingSet`, exponential)
  running during `nimble dump`. Full analysis is in `rewrite_analysis/OLD_CLAUDE.md`.
- **`nimble.paths` is gitignored** by design. Users must run `nimble setup` in the project
  root to generate it. Without it, nimsuggest's internal Nim compiler must call nimble to
  resolve every import.
- **`nimble setup`** generates `nimble.paths` containing `--noNimblePath` + one `--path:`
  per dependency. `config.nims` auto-includes this file. Running it fixed broken imports
  (chronicles, chronos, stew) immediately.
- **Cold-compilation gap is ~11 seconds** with `nimble.paths` forwarded and the correct
  nimble binary on PATH. Subsequent requests are fast (< 1s) due to NimCache on disk.
- **`$HOME` is NOT overridden** by VS Code on this machine. The `getpwuid`-based fix
  described in older issues does not apply here.

---

## Build & test commands

```sh
# Build the langserver binary:
cd langserver && nimble main

# Run a SINGLE test file — always do this, never run all.nim directly:
cd langserver && nim c --path:. -r tests/<file>.nim 2>&1 | tee /tmp/test_output.txt

# Examples:
cd langserver && nim c --path:. -r tests/tnimlangserver.nim 2>&1 | tee /tmp/test_output.txt
cd langserver && nim c --path:. -r tests/tmonorepo.nim 2>&1 | tee /tmp/test_output.txt
```

**DO NOT run `tests/all.nim`** — suites run back-to-back with no gap; port-reuse races
and FD exhaustion make failures hard to isolate. Always run one file at a time.

Config is in `tests/config.nims`. Fixtures live in `tests/projects/`.

---

## Test file status (as of 2026-08-19)

| File | Tests | Status | Notes |
|---|---|---|---|
| `tsuggestapi.nim` | 8 | ✓ all pass | |
| `tmaxlimits.nim` | 4 | ✓ all pass | projectMapping removed; window/logMessage fixed |
| `tknownbug3.nim` | 1 | ✓ all pass | |
| `tstability.nim` | 13 | ✓ all pass | |
| `tmonorepo.nim` | 4 | ✓ all pass | Fix #16 suite removed — `extension/listTests` not registered |
| `tnimlangserver.nim` | 13 | ✓ all pass | |
| `thover.nim` | 1 | ✓ all pass | |
| `tmisc.nim` | 1 | ✓ all pass | idle-timeout suites removed — feature not in rewrite |
| `textensions.nim` | 1 | ✓ all pass | |
| `tmonorepo2.nim` | 3 | ✓ all pass | |
| `tmonorepo3.nim` | 1 | ✓ all pass | |

### Shared infrastructure

- **`tests/fixhelpers.nim`** — `LspSocketClient`, `startServer`, `doInitialize`,
  `waitForNsInit`, `sendDidOpen/Hover/Completion/Change/Save/Rename`. Fixture path
  constants: `simpleRel`, `widgetRel`, `orphanRel`, `orphan2Rel`, `pkgbRel`, `pkgaRel`,
  `aorphanRel`.
- **`tests/tbughelpers.nim`** — multi-project helpers; `startCombinedServer(maxNs)`.
- **`tests/testhelpers.nim`** — general test utilities (kept for reference; `tfindnimblepaths.nim` and `ttestrunner.nim` removed as they tested removed functionality).
- **`tests/lspsocketclient.nim`** — LSP client for tests; `setWorkspaceConfig` helper to
  override the `workspace/configuration` response; uses `while` loops, not tail recursion.

**Config sequencing**: `doInitialize` advertises `workspace.configuration=true`, so the
server's `initialized` handler sends `workspace/configuration`, gets back the overridden
JSON, parses it, sets `currentConfig`, fires `configReady`, then calls
`initNimsuggestInstances`. Tests needing custom config must call
`client.setWorkspaceConfig(%*[{...}])` **before** `doInitialize` + `notify("initialized")`.

### Fixture projects

```
tests/projects/
  hw/                        # minimal hello-world fixture
  testproject/               # standard nimble project fixture
  testrunner/                # test runner integration fixture
  monorepo/                  # two-package monorepo
    pkgb/src/pkgb.nim         # entry point; standalone
    pkga/src/pkga.nim         # entry point; imports pkgb
             aorphan.nim      # NOT imported by pkga.nim
  simple/                    # single-package project (fixhelpers fixtures)
    src/simple.nim            # entry point; imports widget.nim
        widget.nim
        orphan.nim            # NOT imported by simple.nim
        orphan2.nim           # NOT imported by simple.nim
```

`simple/nimble.paths` and `monorepo/nimble.paths` are generated by
`generateSimpleNimblePaths()` / `generateMonorepoNimblePaths()` in fixhelpers.

---


## Directory structure

```
src/
├── nimtortoise.nim             # entry point; main(), registerLspRoutes(), tickLs()
├── protocol/
│   ├── enums.nim               # LSP/MCP enums
│   └── types.nim               # protocol type definitions
├── configurations/
│   ├── configuration_types.nim # NlsConfig, NlsNimsuggestConfig, NlsInlayHintsConfig, …
│   ├── configuration_utils.nim # isDifferentFrom; equality helpers for config types
│   ├── configurations.nim      # config parsing: parseWorkspaceConfiguration, nlsConfigFromJson
│   ├── init_configurations.nim # initDefaultNlsConfig, parseDidChangeConfiguration
│   └── constants.nim           # LSP version, timeout, MAX_CRASH_RETRIES
├── langserver/
│   ├── langserver.nim          # LanguageServer init, pool creation, status, tick,
│   │                           #   getNimbleDumpInfo, nsCapabilities, nsProtocolVersion
│   ├── langserver_types.nim    # LanguageServer, NlsFileInfo, LanguageServerCapabilities,
│   │                           #   LanguageServerFiles, LanguageServerMessaging,
│   │                           #   LanguageServerTransport, CommandLineParams, …
│   ├── transports.nim          # RPC transport layer (stdio / socket)
│   ├── langserver_utils.nim    # URI handling, UTF-8/UTF-16 conversion, stash paths
│   ├── dispatcher.nim          # processLangserverQueue — drains ls.langserverQueue in FIFO;
│   │                           #   handles NIMSUGGEST and FILE_ACCESS branches
│   ├── dispatcher_utils.nim    # isKnownByANimsuggestSlot, addFileToOpenFiles, queryFile,
│   │                           #   nimsuggestSlotToEvict, getLeastRecentlyUsedNimsuggestSlotInFullPool
│   ├── langserver_nimsuggest.nim # getIntendedProject, getWorkingDir, getNimSuggestPathAndVersion,
│   │                           #   initNimsuggestInstances, stopNimsuggestProcesses
│   ├── capability_configs.nim  # usePullConfigurationModel, supportsConfigurationRequest
│   └── query_types.nim         # LangserverQuery (NIMSUGGEST | FILE_ACCESS variant),
│                               #   FileAccessQuery, FileAccessQueryKind
├── handlers/
│   ├── handlers.nim            # re-exports all handler submodules
│   ├── handler_utils.nim       # shared handler utilities (wrapRpc, addRpcToCancellable, …)
│   ├── notification_files.nim  # didOpen, didChange, didSave, didClose, didRenameFiles,
│   │                           #   didDeleteFiles, didChangeConfiguration
│   ├── notification_process.nim # initialized, cancelRequest, setTrace
│   ├── queries_file_access.nim # query helpers for file-level operations
│   ├── queries_nimsuggest.nim  # query helpers for nimsuggest operations
│   ├── request_extension.nim   # extension/status, extension/tasks, extension/tests, etc.
│   ├── request_process.nim     # initialize, shutdown, exit
│   ├── request_text_document.nim # textDocument/* request handlers (hover, completion, def, …)
│   └── request_workspace.nim   # workspace/* request handlers
├── nimsuggest/
│   ├── nimsuggest_types.nim    # NimsuggestQuery, NimsuggestSlot, NimsuggestPool,
│   │                           #   NimsuggestQueryKind, FilePosition, SlotState
│   ├── nimsuggest_slots.nim    # execSpawn, execStop; isLive, isActive, resolvedNs helpers
│   ├── nimsuggest_process.nim  # processNimsuggestQueries, runNimsuggestQuery
│   ├── suggestapi.nim          # nimsuggest TCP protocol: createNimsuggest, sug/def/hover/…
│   └── suggestapi_types.nim    # NimSuggest, Suggest, NimSuggestCapability, Nimsuggest
├── nimble/
│   ├── nimble.nim              # getNimbleEntryPoints
│   ├── nimble_types.nim        # NimbleDumpInfo
│   ├── nimscript_utils.nim     # nimscript helper utilities
│   └── nimscriptapi.nim        # nimscript API template
├── nim_compiler/
│   ├── nim_compiler.nim        # getNimPath, getNimVersion
│   ├── nim_expand.nim          # macro/ARC expansion
│   └── testrunner.nim          # test discovery and execution
├── nph/
│   └── formatting.nim          # nph-based document formatting
└── utils/
    ├── utils.nim               # general utility procs
    ├── asyncprocmonitor.nim    # client process monitoring (hookAsyncProcMonitor)
    └── process_utils.nim       # process utilities
```

**Import path convention**: all inter-module imports use relative paths from each file's
own directory.

---

## Key data structures

### `LanguageServer` type

Defined in `src/langserver/langserver_types.nim`:

```nim
LanguageServer* = ref object
  capabilities*:    LanguageServerCapabilities    # variant on serverMode: lsp | mcp
  configurations*:  LanguageServerConfigurations  # currentConfig + configReady AsyncEvent
  transport*:       LanguageServerTransport        # stdio or socket
  files*:           LanguageServerFiles            # open/idle files, stash, diags
  pool*:            NimsuggestPool                 # slot table + injected procs
  messaging*:       LanguageServerMessaging        # pendingRequests, responseMap, projectErrors
  lspQueue*:        AsyncQueue[LspDispatchItem]    # thin LSP dispatcher queue
  langserverQueue*: AsyncQueue[LangserverQuery]    # FIFO queue for file + nimsuggest work
  notify*:          NotifyAction
  call*:            CallAction
  onExit*:          OnExitCallback
  isShutdown*:      bool
  nimDumpCache*:    Table[string, NimbleDumpInfo]
  cmdLineClientProcessId*: Option[int]
  testRunProcess*:  Option[AsyncProcessRef]
  lsInitialized*:   Future[void]
  ## Completed after initNimsuggestInstances finishes (config + nimble dump +
  ## entry-point spawns). DID_OPEN waits on this before the spawn path so files
  ## are routed to the correct pre-spawned entry-point slot.
```

`pool` is created synchronously in `initLanguageServer` (before the event loop starts)
so it is never nil. `initNimsuggestInstances` (called from the `initialized` handler)
updates `pool.maxSlots` from config and spawns entry-point slots.

`LanguageServerCapabilities` is a variant type on `serverMode`, so LSP and MCP fields
cannot be mixed at the type level.

`langserverQueue` is the single serialization point for all file and nimsuggest work.
`processLangserverQueue` (in `langserver/dispatcher.nim`) drains it in FIFO order,
guaranteeing that a `didChange` stash write is applied before any subsequent hover query
is dispatched to the per-slot mailbox.

### `NlsFileInfo`

Defined in `src/nimsuggest/nimsuggest_types.nim`:

```nim
NlsFileInfo* = ref object of RootObj
  slot*:          NimsuggestSlot   # direct ref to pool slot; assigned in addFileToOpenFiles
  fingerTable*:   seq[seq[tuple[u16pos, offset: int]]]  # UTF-8 → UTF-16 mapping
  lastChanged*:   DateTime         # updated on every DID_CHANGE
  lastChecked*:   DateTime         # set when chkFile or checkProject runs for this URI
  textDocument*:  TextDocumentItem
```

The slot ref is resolved synchronously during `addFileToOpenFiles` (in `dispatcher_utils.nim`)
and stored directly.

### `NimsuggestPool` and `NimsuggestSlot`

See `src/nimsuggest/nimsuggest_types.nim` for the authoritative type definitions.

```nim
NimsuggestPool* = ref object
  slots*:              Table[FilePath, NimsuggestSlot]  # projectFile → slot; all canonical (no aliases)
  maxSlots*:           int                              # pool capacity; 0 = unlimited
  fileCheckDelay*:     times.Duration                   # quiet-period before per-file diagnostics run
  nimsuggestPath*:     string                           # path to nimsuggest binary
  nimVersion*:         string                           # Nim version string for logging
  timeout*:            int                              # per-request timeout in ms
  notifyProc*:         NotifyProc                       # sends JSON-RPC notification to client
  statusChangedProc*:  StatusChangedProc                # triggers extension/statusUpdate
```

Key points:
- `pool.slots` contains only canonical entries — no redirect alias pattern from the old architecture
- Each slot has a `queryMailbox: AsyncQueue[NimsuggestQuery]`; `processNimsuggestQueries` (in `nimsuggest_process.nim`) drains it and dispatches to TCP
- `slot.crashCount` is incremented on `execSpawn` failure; after `MAX_CRASH_RETRIES` the slot gives up and notifies the user
- `execSpawn` backs off exponentially between retries (`1_000 * (1 shl crashCount)` ms, capped at 30s)

---

## Module boundary intent

- `configurations/` — owns `NlsConfig` type and `parseWorkspaceConfiguration`; no LS dependency.
- `nimsuggest/nimsuggest_types.nim` — `NimsuggestQuery`, `NimsuggestSlot`, `NimsuggestPool` types.
- `nimsuggest/nimsuggest_slots.nim` — `execSpawn`, `execStop`; slot state machine.
- `nimsuggest/nimsuggest_process.nim` — `processNimsuggestQueries`, `runNimsuggestQuery`; TCP dispatch. Contains two skip-rule groups: **background queries** (INLAY_HINTS, DOCUMENT_SYMBOLS) are dropped if CHANGED pending or file edited within `FILE_CHECK_DELAY` ms; **position-based queries** (SUGGEST, SIGNATURE_HELP, HOVER, DOCUMENT_HIGHLIGHT) are dropped if a newer same-kind query is already queued for the same URI, or if CHANGED is pending.
- `nimsuggest/suggestapi.nim` — `createNimsuggest`, raw TCP protocol (sug/def/hover/chk/…).
- `langserver/dispatcher.nim` — `processLangserverQueue` (FIFO queue drain).
- `langserver/dispatcher_utils.nim` — `isKnownByANimsuggestSlot`, `addFileToOpenFiles`, `queryFile`, `nimsuggestSlotToEvict`.
- `langserver/langserver_nimsuggest.nim` — `getIntendedProject`, `initNimsuggestInstances`, `stopNimsuggestProcesses`.
- `langserver/langserver.nim` — `initLanguageServer`, `tick`, `getLspStatus`, `nsCapabilities`, `nsProtocolVersion`, `getNimbleDumpInfo`.
- `handlers/` — LSP request/notification handlers; enqueue work onto `ls.langserverQueue`.

---

## The routing layer

`langserverQueue` → `processLangserverQueue` (dispatcher) → per-slot `queryMailbox`

LSP handlers enqueue work items onto `ls.langserverQueue` as `LangserverQuery` objects.
`processLangserverQueue` in `dispatcher.nim` drains the queue in FIFO order:

- `LangserverQueryKind.NIMSUGGEST` → looks up `fileInfo.slot` and calls
  `slot.queryMailbox.addLastNoWait(q)`. This is the serialization point that ensures
  stash writes precede hover queries.
- `LangserverQueryKind.FILE_ACCESS` → executes the file operation inline (DID_OPEN,
  DID_CHANGE, DID_SAVE, DID_CLOSE, etc.)

`queryFile(ls, uri, kind)` in `dispatcher_utils.nim` is the convenience wrapper: creates
a `NimsuggestQuery`, enqueues it on `fileInfo.slot.queryMailbox`, returns the
`Future[seq[Suggest]]` to await. LSP handlers call this instead of `tryGetNimsuggest`.

---

## Startup sequence

1. VS Code → `initialize`
   - Stores `lspInitializeParams`, returns server capabilities
   - Does NOT spawn nimsuggest
2. VS Code → `initialized`
   - Requests config from client (`workspace/configuration`)
   - Waits for config response
   - `initNimsuggestInstances(rootPath)` — with real config; runs nimble dump to get
     `entryPoints`; completes `lsInitialized`
3. VS Code → `textDocument/didOpen <file>`
   - Waits for `lsInitialized` (polls, 60s timeout) — intentional blocking; see design philosophy
   - `isKnownByANimsuggestSlot(pool, uri)` — checks all live slots; returns first that knows the file
   - If known → `addFileToOpenFiles(slot, textDocument)`
   - If unknown → `getIntendedProject(ls, uri)` (projectMapping regex, falls back to file itself)
   - `execSpawn` is `await`-ed inline — intentional; slot must be live before queries reach it
   - `asyncSpawn processNimsuggestQueries(slot, pool)` — starts draining the slot mailbox

---

## The two-table state model

The single most common source of bugs. Always think of them together:

```
ls.files.openFiles   Table[uri → NlsFileInfo]      ← LSP ground truth, all open URIs
slot.ownedUris       HashSet[uri]                   ← Per-slot tracking, subset of openFiles
```

**They are deliberately separate** — there can be multiple nimsuggest slots each owning a
disjoint subset of open files. `slot.ownedUris` tracks which URIs a given slot serves.

**They must be kept in sync manually.** Every `ls.files.openFiles` insertion/deletion must
be mirrored to the correct slot's `ownedUris` via `slot.assignUri(uri)` / `slot.unassignUri(uri)`:

| Operation | `ls.files.openFiles` | `slot.ownedUris` |
|---|---|---|
| `didOpenFile` | `openFiles[uri] = new NlsFileInfo` | `slot.assignUri(uri)` |
| `didCloseFile` | `openFiles.del(uri)` | `slot.unassignUri(uri)` |
| `didRenameFile` | del old, insert new | `unassignUri(old)`, `assignUri(new)` |
| `didDeleteFile` | `openFiles.del(uri)` | `slot.unassignUri(uri)` |

**The deadly pattern**: a `for uri in slot.ownedUris` loop that contains any `await` point.
At each `await`, the Chronos event loop yields and `didCloseFile` can call `unassignUri`,
mutating the set while the iterator is live. **Always snapshot first**: `for uri in slot.ownedUris.toSeq:`.

---

## The stash (dirtyfile) mechanism

1. `textDocument/didOpen` → `addFileToOpenFiles` writes the full initial file content to
   `storageDir/(sha1(uri) & ".nim")` (the stash) immediately and synchronously.
2. `textDocument/didChange` → DID_CHANGE overwrites the stash with new content and updates
   `fileInfo.lastChanged`.
3. When `processLangserverQueue` dispatches any nimsuggest query, it sets `q.dirtyFile`
   at dispatch time (not at query-creation time):
   - If `q.kind == CHANGED and q.saved`: `q.dirtyFile = ""` (use disk)
   - Otherwise: `q.dirtyFile = ls.uriToStash(q.uri)` — which returns the stash path for
     any file currently in `openFiles`, or `""` if the file is closed.
4. `textDocument/didSave` → enqueues a `CHANGED` query with `saved=true`, directing
   nimsuggest back to the on-disk file. After `CHANGED` completes, `CHECK_FILE` is
   enqueued automatically at the front of the slot mailbox.

In v4, nimsuggest calls `msgs.setDirtyFile(fileIndex, dirtyfile)` before any command logic,
so position commands always use the stash content when one is provided.

---

## Request pipeline

```
LSP handler
  → queryFile(ls, uri, kind)           # enqueue NimsuggestQuery on fileInfo.slot.queryMailbox
  → processNimsuggestQueries drains it
      → openTCP to slot.ns.port
      → send command string, read lines until ".\n"
      → if empty: slot transitions to CRASHED (markFailed)
      → else: parse tab-separated Suggest objects
  → map Suggest → LSP types (Location, CompletionItem, Hover, etc.)
  → respond to VS Code
```

---

## Async vs sync rule

A proc must be `{.async.}` only if it has at least one `await`. Chronos's cooperative
scheduler makes sync procs implicitly atomic — nothing else can run between two statements
in a sync proc — which is a correctness property worth preserving.

**Currently sync** (de-asynced from the original):
- `addProjectFileToPendingRequest` — pure table mutation
- `addFileToOpenFiles` — stash write + table mutation + slot assignment
- `queryFile` — enqueue only, returns `Future[seq[Suggest]]` for caller to await

**Invariant for infinite loops**: any `{.async.}` proc that loops indefinitely must use
`while true` + `await sleepAsync(...)`, never tail recursion (`await self()`). Each tail
call in Nim async creates a new closure-backed `Future` object that is not freed until the
entire chain resolves — which for an infinite loop means never (ORC heap corruption).

---

## Unknown-file routing / DID_OPEN branch

`DID_OPEN` in `processLangserverQueue` (`dispatcher.nim`). On open:

1. Wait for `lsInitialized` — blocks the queue until config + entry-point spawns are done.
2. `isKnownByANimsuggestSlot(pool, uri)` — checks all live slots; returns the first that
   knows this file, or none.
3. If known → `addFileToOpenFiles(slot, textDocument)` — assign directly.
4. If unknown → determine `projectFile` via `getIntendedProject(ls, uri)` (projectMapping
   regex lookup, falling back to the file itself as orphan entry point).
5. `await execSpawn(newSlot, ...)` — blocks the queue until nimsuggest is live. Intentional;
   see design philosophy.
6. `asyncSpawn processNimsuggestQueries(slot, pool)` — starts the per-slot drain loop.
7. Consolidation: query other slots via `known` to detect if the new slot subsumes them;
   transfer ownership and stop subsumed slots.

---

## Configuration changes

`workspace/didChangeConfiguration` notifications are processed in the `DID_CHANGE_CONFIGURATION`
branch of the dispatcher. When received:

1. If using the pull model (`usePullConfigurationModel()`), call `workspace/configuration`
   to fetch the current config from the client.
2. Compare to the stored config via `isDifferentFrom`. If different, update
   `ls.configurations.currentConfig` and clear the compiled regex cache.
3. Fire `ls.configurations.configReady` unconditionally (unblocks any startup waiters).

**Nimsuggest instances are never automatically restarted on config change.** Most config
fields (checkOnSave, inlayHints, logNimsuggest, etc.) take effect on the next request
without a restart, since `currentConfig` is read at call time. If a user changes
`nimsuggestPath` or `projectMapping` and needs new instances to reflect the change, they
should use the "Restart nimsuggest" code action.

---

## `nimble.paths` and `config.nims`

- `nimble setup` generates `nimble.paths` in the project root with `--noNimblePath`
  and one `--path:` per dependency.
- `config.nims` auto-includes `nimble.paths` if it exists (standard nimble workflow).
- `nimble.paths` is **gitignored** — every user must run `nimble setup` after cloning.
- `findNimblePaths` reads this file and passes its contents directly to nimsuggest,
  so the Nim compiler inside nimsuggest gets the same paths whether or not it finds
  `config.nims` itself.

---

## LSP handler map

All handlers are registered in `src/nimtortoise.nim` via `registerLspRoutes`.
Implementations are in `src/handlers/` (split across the files listed in the directory
structure above).

### Request handlers (response required)

| LSP Method | Handler file | NS Command(s) sent | Cancellable |
|---|---|---|---|
| `initialize` | `request_process.nim` | none | no |
| `textDocument/completion` | `request_text_document.nim` | `sug` | yes |
| `textDocument/definition` | `request_text_document.nim` | `def` | yes |
| `textDocument/declaration` | `request_text_document.nim` | `declaration` | yes |
| `textDocument/typeDefinition` | `request_text_document.nim` | `type` | yes |
| `textDocument/documentSymbol` | `request_text_document.nim` | `outline` | yes |
| `textDocument/hover` | `request_text_document.nim` | `highlight` | yes |
| `textDocument/references` | `request_text_document.nim` | `use` | no |
| `textDocument/prepareRename` | `request_text_document.nim` | `def` | yes |
| `textDocument/rename` | `request_text_document.nim` | `use` | yes |
| `textDocument/inlayHint` | `request_text_document.nim` | `inlayHints` | yes |
| `textDocument/signatureHelp` | `request_text_document.nim` | `con` | yes |
| `textDocument/formatting` | `request_text_document.nim` | none (nph) | yes |
| `textDocument/documentHighlight` | `request_text_document.nim` | `highlight` | yes |
| `textDocument/codeAction` | `request_text_document.nim` | none (static list) | no |
| `workspace/executeCommand` | `request_workspace.nim` | `recompile`, `chk` | no |
| `workspace/symbol` | `request_workspace.nim` | `globalSymbols` | yes |
| `shutdown` | `request_process.nim` | none | no |
| `exit` | `request_process.nim` | none | no |
| `extension/macroExpand` | `request_extension.nim` | `expand` | no — **STUB** |
| `extension/status` | `request_extension.nim` | none | no — **STUB** |
| `extension/capabilities` | `request_extension.nim` | none | no — **STUB** |
| `extension/suggest` | `request_extension.nim` | restart/check | no — **STUB** |
| `extension/tasks` | `request_extension.nim` | none (nimble) | no |
| `extension/runTask` | `request_extension.nim` | none (nimble) | no |
| `extension/listTests` | `request_extension.nim` | none (nim compile) | no |
| `extension/runTests` | `request_extension.nim` | none (nim run) | no |
| `extension/cancelTest` | `request_extension.nim` | none | no |

### Notification handlers (no response)

| LSP Method | Handler file | NS Command(s) sent | State mutated |
|---|---|---|---|
| `initialized` | `notification_process.nim` | none | `pool`, `entryPoints` |
| `textDocument/didOpen` | `notification_files.nim` → `dispatcher.nim` | `known` | `openFiles`, pool slots |
| `textDocument/didChange` | `notification_files.nim` | none (deferred) | stash file, `lastChanged` |
| `textDocument/willSaveWaitUntil` | `notification_files.nim` | none | — |
| `textDocument/didSave` | `notification_files.nim` | `changed` (saved=true) | `crashedUris` |
| `textDocument/didClose` | `notification_files.nim` → `dispatcher.nim` | none | `openFiles`, `slot.ownedUris` |
| `workspace/didRenameFiles` | `notification_files.nim` | `recompile` | `openFiles`, `slot.ownedUris` |
| `workspace/didDeleteFiles` | `notification_files.nim` | `recompile` | `openFiles`, `slot.ownedUris` |
| `workspace/didChangeConfiguration` | `notification_files.nim` | none | config updated in-place |
| `$/cancelRequest` | `notification_process.nim` | none | `pendingRequests` |
| `$/setTrace` | `notification_process.nim` | none | — |

---

## Nimsuggest v3 vs v4 — critical unknown-file difference

The langserver always starts nimsuggest with `--v4`. The `unknownFile` capability is
**effectively non-functional in v4** for files that were never imported into the project:

| Version | Unknown file behaviour |
|---|---|
| v3 (`executeNoHooks`) | `graph.compileProject(dirtyIdx)` called **unconditionally** before any command — unknown files ARE compiled standalone |
| v4 (`executeNoHooksV3`) | `graph.needsCompilation(fileIndex)` gates `recompilePartially`. For an unknown file, `getModule(fileIndex)` returns nil → `needsCompilation` returns false → `recompilePartially` never called → all commands return `length=0` |

The langserver works around this by using the file itself as the nimsuggest entry point
when it detects the file is unknown to the running instance (fix #18).

---

## Known remaining issues

### P1 — Runtime bugs

1. **Slot eviction mailbox drain race** (`dispatcher.nim`): futures completed with `@[]`
   while `processNimsuggestQueries` may be completing the same futures — violates
   single-write invariant.

### P1 — Stub features (not yet implemented)

2. **`extension/macroExpand`** — stub; macro expansion completely unavailable.
3. **`extension/suggest` (restart action)** — stub; no manual nimsuggest restart button.
4. **`extension/status` / `extension/capabilities`** — stubs; VS Code status bar empty.
5. **Per-file diagnostics only triggered by save**: Diagnostics (`CHECK_FILE`) are only
   enqueued after a `CHANGED` command completes in `processNimsuggestQueries`. Files that
   are open but not explicitly saved receive no periodic re-check.

---

## Consolidated invariants

These constraints must hold in all future code.

1. **Snapshot `slot.ownedUris` before async iteration** — `for uri in slot.ownedUris.toSeq:` not
   `for uri in slot.ownedUris:`. Any `await` inside the loop body allows `didCloseFile` to call
   `unassignUri`, mutating the set while the iterator is live.

2. **Never cancel `ls.configurations.configReady`** — it is a shared `AsyncEvent`; any
   waiter blocked on it will never unblock if the event is cancelled. Do not pass it to
   `utils.withTimeout` or any proc that cancels on timeout. Use polling loops with
   `sleepAsync` instead.

3. **`var p: AsyncProcessRef` in try blocks must check `if p != nil:` in `finally`** — if
   `startProcess` raises before assigning `p`, the `finally` block runs with `p = nil`.
   `shutdownChildProcess(nil)` immediately dereferences the nil ref → SIGSEGV.

4. **`projectErrors` in `extension/statusUpdate` shows commands that failed *after* the crash**,
   not the one that caused it. To find the triggering command, look for the last `DBG Started...`
   with no matching `DBG CPU Time` line.

5. **Stash path uses SHA-1** (`langserver/langserver_utils.nim`: `uriStorageLocation`) —
   `secureHash(string(uri)) & ".nim"` gives ~2^-80 collision probability, acceptable.
   Do not revert to `hash(uri).toHex` (64-bit, collision-prone).

6. **Guard `fileInfo.slot` before use in `didClose`/`didSave` paths** — `slot` in
   `NlsFileInfo` may be nil if `didClose` fires for a URI whose `didOpen` has not yet
   completed slot assignment. Always check `if fileInfo.slot != nil:` before accessing
   `fileInfo.slot.queryMailbox` or calling `slot.unassignUri`.

7. **Infinite loops must use `while true` + `await sleepAsync`**, never tail recursion
   (`await self()`). Each tail call creates a new Future that is never freed until the
   chain resolves — for an infinite loop, never — corrupting the heap under ORC.

---

## Debugging approach

Add `debug "..."` calls with the `chronicles` library. The VS Code LSP trace log
(`"nim.logNimsuggest": true`) captures both protocol messages (timestamped) and
langserver debug output in one file. Debug logs at all nimble call sites print `HOME`,
`PATH`, and `NIMBLE_DIR` to identify which binary is being used. When investigating
crashes, check `projectErrors` in `extension/statusUpdate` for post-crash failed commands,
then search backwards in the log for the last `DBG Started...` with no matching
`DBG CPU Time` to find the command that triggered the crash.

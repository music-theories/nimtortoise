# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.4] - 2026-08-18

### Added

#### Forest — Fast Dependency Tree Mapper
A new standalone library (`/forest/`) that builds a complete dependency graph for
a Nim project by combining `nim dump` and `nimble dump` metadata. Processes a
100,000-line codebase in under one second.

Key components:
- `dependency_tree.nim` — builds and traverses the full import graph
- `forest_types.nim` — type definitions for the graph model
- `init_forest.nim` — async initialisation entry point
- `nim_dump.nim` / `nimble_dump.nim` — metadata parsers for the Nim compiler and
  Nimble package manager
- `resources.nim` — resource type abstraction over files, packages, and search paths
- Comprehensive reference documentation (`forest/README.md`) covering every
  Nim project file type (`.nim`, `.nimble`, `nimble.paths`, `nimble.lock`,
  `nimble.develop`, `config.nims`, `.nims`, `nim.cfg`), how they relate, and
  how the compiler resolves them

The forest is now used by the language server to determine the correct nimsuggest
entry point for each file opened in the editor. This replaces the old
heuristic-only approach and is the root fix for the missing diagnostics bug
described below.

#### Dependency Checking
The language server now verifies at startup, and on each file open, that a file is
reachable from its project entry point. Files that are orphaned (not imported by
any entry point) are handled gracefully rather than causing silent failures.

#### Readable Type Mismatch Hover Messages (`utils/type_mismatch_format.nim`)
New 361-line utility for formatting type mismatch errors in hover information:
- `extractLastType()` extracts the final type from a colon-separated string
- `splitBySemicolon()` parses parameter lists while respecting bracket nesting
- `extractProcParamTypes()` decomposes procedure signatures into readable
  parameter type lists
- Handles nested generics, optional types, and parameters with default values

#### Extension Protocol Definitions (`protocol/extensions.nim`)
Formalised the extension capabilities the server advertises and understands:
```nim
type LspExtensionCapability* = enum
  excRestartSuggest = "RestartSuggest"
  excNimbleTask     = "NimbleTask"
  excRunTests       = "RunTests"

type NimSuggestCapability* = enum
  nsCon                = "con"
  nsExceptionInlayHints = "exceptionInlayHints"
  nsUnknownFile        = "unknownFile"
```
Also added `NimLangServerStatus` for querying full server diagnostics,
`SuggestParams`/`SuggestResult` for restart actions, `NimbleTask` for listing
available tasks, and `RunTaskParams` for task execution.
 d
#### Nimsuggest Entry Point Selection (`nimble/nimble_utils.nim`)
New `getNimsuggestSpawnInfo()` function determines the correct entry point for any
file using the Forest:
1. Walk up the directory tree from the opened file to find the nearest `.nimble`
2. Query the Forest for all entry points within that project
3. Select the entry point with the longest common path prefix to the opened file
4. Fall back to the file itself if it is an orphan with no matching entry point

#### Per-File Dispatcher Modules
- `dispatcher_did_open.nim` (260 lines) — all logic for handling `textDocument/didOpen`
- `dispatcher_did_change.nim` (131 lines) — stash management for `textDocument/didChange`

Extracted from the monolithic dispatcher to isolate the most complex stateful
notification handlers.

#### Nimsuggest Query Utilities
- `suggestapi_queries.nim` (145 lines) — query parameter validation,
  deduplication, and state-aware filtering
- `suggestapi_utils.nim` (179 lines) — path resolution, response parsing, and
  capability detection helpers

#### Configuration Robustness
- `NlsConfig` struct with explicit defaults prevents nil-dereference bugs
- `isDifferentFrom()` comparison avoids unnecessary nimsuggest restarts when
  a configuration change notification arrives with unchanged values
- `initDefaultNlsConfig()` / `parseDidChangeConfiguration()` centralise all
  config initialisation

---

### Fixed

#### Massive Missing Diagnostics Bug
The most impactful fix in this release. Diagnostics (errors, warnings, hints)
were silently dropped for large numbers of files because each file was being
routed to the wrong nimsuggest slot. The entry point selection logic used simple
string heuristics that failed for projects with multiple entry points or
non-standard layouts. Replaced with Forest-backed routing via
`getNimsuggestSpawnInfo()`.

#### Four Queuing and Dispatch Bugs

1. **`queryFile` completion race** — `queryFile` previously added work to a
   mailbox even when the slot was in `STOPPED` or `CRASHED` state, producing
   futures that would never complete. It now returns immediately with an empty
   result for dead slots.

2. **`DID_CLOSE` deadlock** — the close handler was awaiting `CHECK_FILE`,
   which could block indefinitely if the slot had stopped. `DID_CLOSE` is now
   fire-and-forget; it does not await the check.

3. **Crash respawn loop** — `attemptCrashRespawn` called `execStop` after
   detecting a crash. This left the freshly respawned slot permanently ignoring
   its mailbox because `execStop` had already drained it. The `execStop` call
   is no longer made post-crash.

4. **`DID_CHANGE` slot state check** — the change handler enqueued work without
   first checking slot state. STOPPED/CRASHED slots now receive an immediate
   `complete(@[])` instead of accumulating orphaned futures.

#### Exceptions Not Being Caught
Exception handling added throughout the Forest initialisation and dependency tree
parsing paths. Parse failures in resource utilities are now reported with a
structured error message rather than crashing the surrounding async task.

#### Multiline Comment Autocomplete
Fixed incorrect closing token insertion when the cursor was inside a multiline
comment block.

#### Timeout Bug
Fixed timeout handling in nimsuggest query dispatch where a timed-out query could
leave the slot in an inconsistent state, causing all subsequent queries to that
slot to also time out.

---

### Changed

#### Protocol Layer Split
The single `protocol/types.nim` (1,198 lines) was split into focused modules:

| New module | Content |
|---|---|
| `protocol/lsp_basic.nim` | `Position`, `Range`, `Location`, `TextEdit`, etc. |
| `protocol/lsp_capabilities.nim` | `ServerCapabilities` and all sub-capability types |
| `protocol/lsp_diagnostics.nim` | `Diagnostic`, `DiagnosticSeverity`, related types |
| `protocol/lsp_protocol.nim` | Core request/response/notification envelope types |
| `protocol/mcp.nim` | MCP protocol types |
| `protocol/extensions.nim` | Extension capability enums and request/response types |
| `protocol/primitives.nim` | Primitive aliases used across other modules |

#### Handler Reorganisation
LSP handlers moved from a single file into a per-domain structure:

| New module | Handles |
|---|---|
| `handlers/request_text_document.nim` | `textDocument/*` requests |
| `handlers/request_workspace.nim` | `workspace/*` requests |
| `handlers/request_extension.nim` | `extension/*` requests (330-line rewrite) |
| `handlers/request_process.nim` | `initialize` / `shutdown` / `exit` |
| `handlers/notification_files.nim` | `didOpen`, `didChange`, `didClose`, `didSave` |
| `handlers/notification_process.nim` | Process-level notifications |

#### `ProjectError` Extended
Now carries three fields instead of one:
- `projectFile` — which project triggered the error
- `errorMessage` — what went wrong
- `lastKnownCmd` — which nimsuggest command caused the failure

This information is surfaced in `NimLangServerStatus` responses and in VS Code
status bar tooltips.

#### `.vscode/settings.json`
Switched all 18 settings entries from `nim.` to `nimTortoise.` prefix to prevent
conflicts when the standard nimlangserver extension is also installed.

#### `nimscriptapi.nim` Updated
Synced with the upstream version.

---

### Summary

81 files changed — 5,666 insertions, 3,127 deletions.

The central theme of this release is correctness. The Forest-backed entry point
selection finally gives the language server an accurate picture of which
nimsuggest process should handle each file, eliminating the class of silent
failures that made diagnostics unreliable for multi-entry-point projects. The four
dispatcher fixes independently address concurrency hazards that compounded those
failures. The protocol and handler refactors are the structural foundation for all
further feature work.

## [0.1.3] - earlier

See git history.

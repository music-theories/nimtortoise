# nimsuggest

`nimsuggest` is the IDE backend for Nim. This document covers what it is, how it works,
its TCP protocol, all its query types, the dirty-file mechanism, and every quirk and bug
uncovered during the rewrite of this language server.

---

## What nimsuggest Is

Nimsuggest is **not** a static analyser or a symbol database. It is a **running Nim
compiler** that has compiled your project from an entry point and holds the resulting
module graph in memory. When you ask for hover information on `foo.bar`, nimsuggest looks
up `bar` in the type-checked AST of the module that defines `foo`. It cannot look up
anything it was not asked to compile.

This has one non-negotiable consequence: **nimsuggest can only serve files that are
transitively imported from its entry point**. If your entry point is `src/main.nim` and
it imports `src/utils.nim`, nimsuggest knows `utils.nim`. If `src/other.nim` is not
imported by `main.nim`, nimsuggest does not know it, and hover/completion/definition
for that file will silently return nothing.

### Entry points

The entry point is the single `.nim` file passed as the first argument to nimsuggest —
the same file you would pass to `nim c`. Choosing the wrong entry point is the most
common source of IDE feature failures. See also: [nimble.md](nimble.md) for how nimble's
`entryPoints` field drives entry point selection.

---

## Protocol Versions

Nimsuggest supports two protocol versions, selected by flags at spawn time.

### v3 (default without flag)

- `executeNoHooks` is called before each command
- Calls `graph.compileProject(dirtyIdx)` **unconditionally** for every command
- Unknown files (not in module graph) are compiled standalone before serving
- Slower, but handles orphan files correctly

### v4 (`--v4` flag)

- `executeNoHooksV3` is called instead
- `graph.needsCompilation(fileIndex)` gates `recompilePartially`
- **Critical**: for an unknown file, `getModule(fileIndex)` returns `nil` →
  `needsCompilation` returns `false` → `recompilePartially` never called → all position
  queries return `length=0` silently
- The `unknownFile` capability is **advertised** in v4 but **non-functional** for files
  not in the module graph

**This langserver always uses `--v4`.** The workaround for unknown files is to spawn a
separate nimsuggest with the unknown file itself as entry point (see "Two-Tier Spawn
Strategy" below).

---

## Invocation

```
nimsuggest <entry-point.nim> [flags...]
```

### Flags used by this langserver

| Flag | Purpose |
|---|---|
| `--v4` | Use protocol v4 (always passed) |
| `--autobind` | Auto-select an available port; prints port number on stdout |
| `--clientProcessId:<pid>` | v4+ only; nimsuggest exits when this PID exits |
| `--log` | Enable nimsuggest debug logging (controlled by `nim.logNimsuggest`) |
| `--exceptionInlayHints:off` | **Always hardcoded off** — see critical bug below |
| `--path:<dir>` | Add directory to Nim compiler search path (from `nimble.paths`) |
| `--noNimblePath` | Prevent compiler from scanning `~/.nimble/pkgs2/` |

### Working directory

The process working directory is set to the nimble project root. This lets the Nim
compiler embedded in nimsuggest find `config.nims` via its ancestor walk, without needing
all paths to be passed explicitly. See [configs.md](configs.md) for how the search works.

### Port discovery

After spawning, nimsuggest prints its listening port on stdout:
```
nimsuggest serving on port 52229
```
The langserver reads this line (with a configurable timeout, default 60 seconds). If the
line does not appear before timeout, nimsuggest is considered to have crashed on startup.

---

## TCP Communication Protocol

Nimsuggest listens on `127.0.0.1:<port>` (localhost only).

### Connection model

A **new TCP connection is opened for each query** — there is no persistent connection or
multiplexing. This is not a bug; it is how the protocol is designed.

### Request format

```
<command> "<file>";<"dirtyfile">:<line>:<col>[tag]\c\L
```

- `<command>` — one of the query types listed below (e.g. `sug`, `def`, `chkFile`)
- `"<file>"` — absolute path to the file being queried, double-quoted
- `;<"dirtyfile">` — optional; if omitted, nimsuggest uses the on-disk file; if present,
  nimsuggest uses the dirty file's contents as if it were the real file
- `:<line>:<col>` — 1-based line, 0-based column (some commands omit these)
- `[tag]` — optional tag appended after column (used by `inlayHints`)
- `\c\L` — CRLF line ending required

**Example requests:**
```
sug "/home/user/project/src/main.nim";"/home/user/.cache/tortoise/abc.nim":42:10\r\n
def "/home/user/project/src/main.nim":47:3\r\n
chkFile "/home/user/project/src/main.nim"\r\n
```

### Response format

- Tab-separated fields, one result per line
- The string `"."` on a line by itself marks the end of the response
- An empty response (no lines before `"."`) means no results
- **An empty response where content was expected (e.g. on `sug`) indicates a crash**

### Parsed fields (from `parseSuggestDef`)

| Index | Field | Notes |
|---|---|---|
| 0 | `section` | e.g. `sug`, `def`, `chk`, `outline` |
| 1 | `symKind` | symbol kind: `proc`, `var`, `type`, etc. |
| 2 | `qualifiedPath` | fully qualified symbol name |
| 3 | `forth` | type information; `Error`/`Warning`/`Hint` for diagnostics |
| 4 | `filePath` | absolute path to definition |
| 5 | `line` | 1-based |
| 6 | `column` | 0-based |
| 7 | `doc` | docstring or full error message (after `unescape()`) |
| 8 | (unused) | |
| 9 | `endLine` | only when 11 tokens (definition/reference results) |
| 10 | `endCol` | only when 11 tokens |

`endLine`/`endCol` are absent for check errors.

### Timeouts

- Per-request timeout: 120 seconds (configurable via `nim.nimsuggestRequestTimeout`)
- Spawn timeout: 60 seconds (configurable via `nim.nimsuggestSpawnTimeout`)
- Timeout on a query → connection closed → slot marked CRASHED → crash recovery begins

---

## Query Types

All commands supported by nimsuggest v4, as used by this langserver:

| Command | String | Purpose | Position required? |
|---|---|---|---|
| `SUGGEST` | `sug` | Completion items at cursor | Yes |
| `DEFINITION` | `def` | Go-to-definition | Yes |
| `DECLARATION` | `declaration` | Go-to-declaration | Yes |
| `TYPE_DEFINITION` | `type` | Go-to-type-definition | Yes |
| `REFERENCES` | `use` | Find all references | Yes |
| `DOCUMENT_SYMBOLS` | `outline` | File symbol tree | No (file only) |
| `WORKSPACE_SYMBOLS` | `globalSymbols` | Workspace-wide symbol search | No |
| `HOVER` | `highlight` | Symbol information at position | Yes |
| `DOCUMENT_HIGHLIGHT` | `highlight` | All occurrences of symbol in file | Yes |
| `SIGNATURE_HELP` | `con` | Overload list at call site | Yes |
| `INLAY_HINTS` | `inlayHints` | Type/parameter/exception hints for range | Range |
| `EXPAND` | `expand` | Macro expansion at position | Yes |
| `CHANGED` | `changed` | Notify nimsuggest of unsaved edits | No |
| `CHECK_FILE` | `chkFile` | Per-file diagnostics | No (file only) |
| `CHECK_PROJECT` | `chk` | Full project diagnostics | No |
| `RECOMPILE` | `recompile` | Force full in-process recompile | No |
| `KNOWN` | `known` | Is this file in the module graph? | No (file only) |

**Note on `HOVER` and `DOCUMENT_HIGHLIGHT`**: Both dispatch to the same `highlight`
nimsuggest command. The `highlight` response returns symbol information for the token at
the cursor position plus all occurrences of that symbol in the file. The langserver uses
the first result's type/doc fields for hover, and the full list of locations for document
highlight. Nimsuggest has no separate hover command.

### `inlayHints` range format
```
inlayHints "<file>":<startLine>:<startCol>:<endLine>:<endCol>:<options>
```

### `known` command
Returns a boolean-style response: a single result where the `forth` field is `"true"` if
the file is in the module graph, or an empty result set (just `"."`) if it is not. The
langserver checks `sug[0].forth == "true"` to decide whether an existing slot can serve a
newly opened file.

---

## The Dirty File (Stash) Mechanism

Nimsuggest works with on-disk files by default. To support analysis of unsaved edits, it
accepts a "dirty file" path: a temporary copy of the file with the current unsaved content.

### How this langserver uses it

1. **`textDocument/didOpen`** — full file content written to `storageDir/(sha1(uri) & ".nim")` (the "stash")
2. **`textDocument/didChange`** — stash overwritten with new content; `fileInfo.lastChanged` updated
3. **Query dispatch** — `q.dirtyFile` set at dispatch time (not at query-creation time):
   - If the file has unsaved changes: `q.dirtyFile = stashPath`
   - If the file is saved: `q.dirtyFile = ""`  (nimsuggest reads the on-disk file)
4. **`textDocument/didSave`** — enqueues a `CHANGED` query with `saved=true` and empty `dirtyFile`,
   directing nimsuggest back to the on-disk file
5. **SHA-1 hash** for stash filenames (`secureHash(uri) & ".nim"`) — gives ~2^-80 collision
   probability. Do not revert to `hash(uri).toHex` (64-bit; collision-prone at scale).

### Why dirty files matter

Without the stash mechanism, nimsuggest would only see the last saved version of each
file. Type errors would only appear after saving. Hover information would be wrong for
recently typed code. The stash ensures nimsuggest always has the current editor content.

---

## Entry Points and the `known` Command

When a file is opened, the langserver must decide which nimsuggest slot to use. The
decision flow:

1. Send `known <file>` to each live slot
2. If any slot returns the file in its response → assign file to that slot
3. If no slot knows the file → determine a project entry point via `projectMapping` or
   nimble `entryPoints`; spawn a new slot with that entry point; wait for it to be ready

**Critical rule**: `known` is a membership check in the module graph at the time of the
query. If the file was never imported from the entry point, `known` returns false forever —
regardless of how long you wait. The module graph is fixed at spawn time.

**Race condition during cold compile**: `known` queries sent while nimsuggest is still
building its initial module graph (can take 10–25 seconds) may time out. The langserver
treats a timeout as "not known" and may spawn an unnecessary standalone slot. This is
cosmetic; it self-resolves once the cold compile finishes and the slot is reused on the
next open.

---

## Two-Tier Spawn Strategy

This langserver uses a two-tier strategy when a file is opened that belongs to a project:

**Tier 1 (immediate)**: Spawn nimsuggest with the opened file itself as entry point, using
the nimble directory as working dir. Fast (~10 seconds for a sub-module). Serves queries
immediately so the user is not waiting.

**Tier 2 (background)**: Simultaneously spawn nimsuggest with the real module entry point
in the background via `attemptModuleSpawnInBackground`. This gives full project-wide
context (cross-file go-to-definition, project-wide completions, full diagnostics).

**Consolidation**: If Tier 2 succeeds, all Tier-1 slots whose files are in Tier 2's
module graph are stopped and their owned URIs transferred to the Tier 2 slot. If Tier 2
fails (crashes), the entry point is added to `pool.crashedSlots` and future opens skip
the background attempt — Tier 1 IntelliSense continues indefinitely.

---

## Cold vs Warm Startup

Nimsuggest's first query for a project requires a full Nim compilation from the entry
point. All subsequent queries are fast because nimsuggest holds the compiled module graph
in memory and benefits from NimCache on disk.

| Condition | Startup time |
|---|---|
| Cold cache, no `--path:` flags | ~40 seconds |
| Cold cache, with `--path:` flags from `nimble.paths` | ~25 seconds |
| Warm NimCache, with `--path:` flags | ~11 seconds |
| Already-running nimsuggest, any query | < 1 second |

The single biggest improvement is passing `--path:` and `--noNimblePath` from
`nimble.paths` (run `nimble setup` after cloning to generate it). NimCache then
eliminates the remaining generic-instantiation cost on subsequent starts. For NimCache
location, clearing instructions, and a full forensic breakdown of each startup phase,
see [nim.md](nim.md) and [performance.md](performance.md).

---

## Critical Bugs and Quirks

This section documents every significant bug and non-obvious behaviour discovered during
the rewrite. Most of this information is not documented upstream.

---

### `--exceptionInlayHints:on` Causes Catastrophic Hang

**Severity**: Critical. Causes nimsuggest to hang indefinitely until spawn timeout.

**Affected codebases**: Any project that combines:
1. Extensive use of generics (e.g. `Future[T]`, deeply nested generic types)
2. Heavy macro/template use
3. Code that contains errors or is incomplete (common during development)

**Symptom**: Nimsuggest spawns but never prints its port. The spawn timeout (default 60s)
fires, the slot is marked CRASHED, crash recovery begins, and all subsequent spawns also
hang. The user gets permanent "per-file only" IntelliSense from Tier 1 with no
cross-project features.

From the trace (`traces/2026-08-18r.txt`): a Tier 1 spawn (small sub-module file as
entry point) succeeded in ~18 seconds; a Tier 2 spawn (full module entry point,
`user_interfaces.nim`) hung until timeout. The only difference between the two was that
the full entry point pulled in the entire project's generic/macro complexity.

**Root cause**: Exception inlay hints require nimsuggest to compute the `raises` effect
set for every proc it compiles, by walking the entire call graph and propagating `raises`
sets upward. Three factors cause this to diverge:

1. **Generics**: each instantiation of a generic proc with different type parameters can
   have a different `raises` set. The compiler must instantiate and analyse each one
   separately. `Future[T]`-heavy codebases create a combinatorial explosion.

2. **Macros and templates**: expand at compile time and generate more generic code, which
   creates more instantiations, which need more effect inference — a compounding loop.

3. **Incomplete code**: in normal compilation the compiler short-circuits on errors; in
   nimsuggest's persistent mode it tries to recover and keep going, leaving the `raises`
   graph in an inconsistent state. Inference may then loop, revisiting nodes because the
   "settled" state is never reached.

This is structurally identical to nimble's SAT solver blowup — both are theoretically
exponential algorithms that work on small inputs and blow up on large, complex, real-world
codebases.

**Workaround**: Always pass `--exceptionInlayHints:off`. This is hardcoded in this
langserver (`suggestapi_queries.nim`) and cannot be overridden by user config:

```nim
# THIS NEEDS TO ALWAYS BE OFF TO PREVENT THE COMPILER SHITTING THE BED
# ON LARGE CODEBASES WITH GENERICS, MACROS AND TEMPLATES.
result.add("--exceptionInlayHints:off")
```

The inlay hints `exceptionHints.enable` setting therefore has no effect on the
`--exceptionInlayHints` flag passed to nimsuggest, regardless of user preference.

**Upstream fix needed**: The Nim compiler's `raises` inference engine needs one of:
1. A depth/iteration limit — bail out and report `raises: [Exception]` (conservative)
2. A cycle detector — break out if the same node is visited more than N times
3. Skip exception inference during error recovery

**Discovered**: 2026-08-18 by comparing spawn outcomes with flag on vs off.

---

### SIGSEGV is a Restart Signal, Not a Bug

Nimsuggest does not attempt to recover from corrupted module graph state — it crashes
rather than continuing with corrupted state. The effect is "crash loudly and let the
supervisor restart cleanly" rather than "limp on with wrong answers", but the SIGSEGV
itself is a genuine segmentation fault (invalid memory access), not a deliberate signal.

Common triggers:
- File rename while a query is in flight
- Module graph corruption from `recompilePartially` double-compilation (see split-identity below)
- Certain autocomplete scenarios on a corrupted graph

The SIGSEGV is detected via an empty TCP response. The langserver logs the crash, begins
exponential-backoff retry, and eventually re-serves the file from a fresh nimsuggest.

---

### Split-Identity Type Mismatch

**Symptom**: Nimsuggest reports a type error of the form:
```
type mismatch:
 got 'MyType[T]' [object declared in foo.nim(45, 3)]
 but expected 'MyType[T]' [object declared in foo.nim(45, 3)]
```
The type names are **identical**, pointing to the **same source location**. This is
impossible in correct code — it only arises when `recompilePartially` compiles the same
module twice, creating duplicate `PSym` objects for what should be one type. Each
duplicate is a distinct pointer identity, so the type checker considers them different
types.

**Second symptom**: Phantom circular dependencies. Nimsuggest reports:
```
This might be caused by a recursive module dependency:
/…/dispatcher.nim imports /…/nimtortoise.nim
/…/nimtortoise.nim imports /…/dispatcher.nim
```
...for cycles that do not exist in the source files. The cycle detector walks `PSym`
objects by pointer identity; two duplicate `PSym` objects for the same module look like
two nodes, and traversing from one to the other looks like a cycle.

**Third symptom**: "undeclared identifier" for a symbol that provably exists. After the
duplicate PSym creation, the symbol exists in one copy of the module but the import
chain resolves to the other.

**Recovery**: The `RECOMPILE` command forces nimsuggest to rebuild the module graph from
scratch, eliminating all duplicate PSyms. This langserver detects split-identity errors
automatically via `isExactSplitIdentityTypeMismatch` and prepends a `RECOMPILE` to the
query mailbox before publishing diagnostics.

**Detection**: Two error formats exist (from `type_mismatch_format.nim`):
- **Format 1** (direct compatibility): starts with `type mismatch:`, contains `got 'X'`
  and `but expected 'X'` with same `[object declared in ...]` annotation — definitive
- **Format 2** (overload resolution): starts with `type mismatch` (no colon), contains
  `Expected one of (first mismatch at [position]):` — split-identity when qualified
  type name equals unqualified proc signature type name

**Important**: Loose detection (Format 2 base-name matching only) must never trigger
auto-RECOMPILE — it can false-positive when two genuinely distinct types from different
modules share a base name. Only exact matches trigger RECOMPILE; loose matches show an
advisory note only.

---

### `unknownFile` Capability Non-Functional in v4

Nimsuggest advertises the `unknownFile` capability in its capabilities output. In
protocol v3, this allowed nimsuggest to compile and serve a file that was not in the
initial module graph by calling `graph.compileProject(dirtyIdx)` unconditionally before
each command.

In v4, `executeNoHooksV3` gates the recompilation behind
`graph.needsCompilation(fileIndex)`. For a file that was never imported, `getModule(fileIndex)`
returns `nil`, `needsCompilation` returns `false`, and no recompilation happens. All
position queries (hover, completion, definition) return `length=0`.

Do not attempt to serve unknown files via an existing v4 slot. Instead, spawn a new slot
with the unknown file as its entry point.

---

### nimsuggest Version Must Match nim Version

The `nimsuggest` binary is tightly coupled to the Nim compiler it was built with. The two
share the same AST, type system, and standard library. A version mismatch causes:
- Crashes due to incompatible AST node layouts
- Wrong type information from mismatched stdlib
- Silent failures where nimsuggest uses a different stdlib tree than the project

```bash
nim --version | head -1
nimsuggest --version | head -1
# Both must report the same version
```

On macOS with Homebrew + choosenim, two nim/nimsuggest pairs can coexist on PATH. The
wrong one being picked (especially in Dock-launched VS Code with restricted PATH) is a
common source of unexplained failures. See [nimble.md](nimble.md) for the PATH issue.

---

### Multiple Simultaneous Processes Double Resource Usage

Each nimsuggest process loads the full Nim standard library and the project's transitive
dependency graph into memory. A single instance on a large project can consume 200–400 MB
RAM. Two competing Nim extensions (e.g. `nimlang.nimlang` + `kosz78.nim`) each spawn
their own process pool, doubling memory and CPU usage and potentially fighting over ports.

Only one Nim LSP extension should be active. Disable any others.

---

### nimlangserver 1.12.0 Crash Loop

Nimlangserver 1.12.0 has a bug where it crashes with `EXC_BAD_ACCESS` / SIGSEGV inside
`lstransports::writeOutput` early in startup. The crash creates a specific pattern:

1. VS Code opens a file → nimlangserver launches nimsuggest with the opened file as root
   (before reading the correct entry point from `.nimble`)
2. Nimsuggest starts indexing from the wrong file → 100% CPU spike
3. Nimlangserver crashes at `lstransports::writeOutput`
4. VS Code detects crash → restarts nimlangserver
5. New nimlangserver finds the still-running (wrong-rooted) nimsuggest via `--autobind`
6. Loop continues indefinitely

**Diagnosis**:
```bash
nimlangserver --version   # if "1.12.0", this is your problem
ps aux | grep nimsuggest  # path after nimsuggest should be the entry point, not a deep src file
ls ~/Library/Logs/DiagnosticReports/nimlangserver*.ips | wc -l  # >2-3 confirms loop
```

**Fix**: Upgrade to nimlangserver 1.14.0 or later:
```bash
cd ~ && nimble install nimlangserver@1.14.0 -y
```

---

## Crash Recovery

### Slot state machine

```
STOPPED → SPAWNING → READY → STOPPING → STOPPED
                  ↓
                CRASHED → (backoff) → SPAWNING
```

### Exponential backoff

On each crash or spawn failure:
- Retry delay: `min(1_000 * (1 shl min(crashCount-1, 14)), 30_000)` ms (1s, 2s, 4s, 8s... capped at ~30s)
- After `maxNimsuggestCrashRetries` failures (default 3): slot permanently removed from pool
- User notified via `window/logMessage`

### Per-file crash tracking

`slot.crashedUris` tracks files that caused crashes. Files in `crashedUris` are not
retried — the slot is considered permanently damaged for those files.

**Clearing**: A `textDocument/didSave` on a crashed-URI file clears it from `crashedUris`
before retrying, allowing recovery after the user fixes the code that caused the crash.

### Manual restart

The `extension/suggest` code action ("Restart nimsuggest") clears `crashedFiles` for the
entire project and forces a fresh spawn. As of the current rewrite this is a stub
awaiting implementation.

---

## Transitive Dependency Diagnostics

This section documents how nimsuggest propagates diagnostics across multi-file dependency
chains, and the manual cascade technique required to work around its single-level
`markClientsDirty` behaviour.

---

### How `executeNoHooksV3` Stores Errors

In v4, every command (including `changed`, `chkFile`, `chk`) routes through
`executeNoHooksV3` in `nimsuggest/nimsuggest.nim`. This proc **overwrites
`conf.structuredErrorHook`** at the start of each call to store errors into
`graph.suggestErrors` — a `Table[FileIndex, seq[Suggest]]`:

```nim
conf.structuredErrorHook = proc (conf: ConfigRef; info: TLineInfo; msg: string; sev: Severity) =
  let suggest = Suggest(section: ideChk, filePath: toFullPath(conf, info), ...)
  graph.suggestErrors.mgetOrPut(info.fileIndex, @[]).add suggest
```

Errors accumulate in this table during recompilation. They are emitted to the client only
when an explicit read command runs:

- `ideChk` (`chk`) — emits all entries in `suggestErrors` for all files
- `ideChkFile` (`chkFile`) — emits only `suggestErrors[fileIndex]` for the queried file
- `markDirty(fileIdx)` — **clears** `suggestErrors[fileIdx]` as a side effect

This means **no recompilation = no errors**, regardless of what is dirty. A `chkFile`
on a file that does not need compilation simply returns whatever was already in
`suggestErrors[fileIdx]` — which may be empty.

---

### `markClientsDirty` is ONE Level Only

When `changed file_a ; stash` is processed, nimsuggest calls:

1. `markDirtyIfNeeded(stash, file_a_idx)` — marks file_a sfDirty, clears its `suggestErrors`
2. `markClientsDirty(file_a_idx)` — marks direct importers sfDirty

The critical constraint: `markClientsDirty` does **not** compute the transitive closure.
In `compiler/modulegraphs.nim` line 838, the transitive invalidation is explicitly
commented out:

```nim
# invalidTransitiveClosure = true
```

Only the one-hop set of direct importers is marked. Given the chain:

```
dependencies.nim → file_c → file_b → file_a
```

After `changed file_a`:
- file_a → sfDirty ✓
- file_b → sfDirty ✓ (direct importer of file_a)
- file_c → **not dirty** ✗ (two hops away)
- dependencies.nim → **not dirty** ✗ (three hops away)

---

### Why `recompilePartially` Skips Clean Files

`ideChk` and `ideChkFile` call `recompilePartially` (or `recompilePartially(moduleToCompile)`
for per-file commands). The entry function in `compiler/pipelines.nim` walks the module
graph starting from the project root (for `ideChk`) or a specific module (for `ideChkFile`).

A module is only recompiled if `graph.isDirty(module)` — i.e. `sfDirty in module.flags`.
If file_c is not sfDirty, `compilePipelineModule(file_c)` returns its cached result
immediately without running the type checker. No new errors are generated; `suggestErrors`
for file_c remains empty.

Consequence: after `changed file_a`, a bare `chkFile file_c` returns 0 errors — not because
file_c is correct, but because nimsuggest never recompiled it.

When a module **is** recompiled, `compilePipelineModule` (in `compiler/pipelines.nim`) ends
by calling:

```nim
result.excl sfDirty
graph.markClientsDirty(fileIdx)   # one hop: marks direct importers sfDirty
```

This is the propagation mechanism that can be chained manually (see below).

---

### The Manual Cascade Technique

Because `markClientsDirty` is one-hop, the langserver must manually thread the dirty signal
through intermediate non-open files before checking open dependents. The technique is:

**Step 1 — Self-check the changed file with its stash:**
```
chkFile file_a ; stash_a
```
file_a is sfDirty (from `changed`) → recompiled from stash → `markClientsDirty(file_a_idx)`
→ file_b becomes sfDirty

**Step 2 — Check each non-open intermediate file (no stash):**
```
chkFile file_b ; ""
```
file_b is sfDirty → recompiled against the updated file_a types → `markClientsDirty(file_b_idx)`
→ file_c becomes sfDirty

**Step 3 — Check the open dependent with its stash:**
```
chkFile file_c ; stash_c
```
file_c is now sfDirty → recompiled from stash (in-memory content) → type error propagates
through the chain → `suggestErrors[file_c_idx]` populated → response returned to langserver

The intermediate files (file_b in this example) are discovered via `findIntermediatePath`
from `forest/src/forest/dependency_tree_utils.nim`. Open dependent files are found by
walking `openFiles` and calling `isDependency`.

**Queue ordering**: The langserver uses `addFirstNoWait` to prepend to the query mailbox,
so items must be added in **reverse execution order** — open dependents first, then
intermediates, then the self-check last (so it ends up at the queue front).

| Add order | `addFirstNoWait` call | Queue state after |
|-----------|----------------------|-------------------|
| 1st | CHECK_FILE(file_c, stash_c) | [file_c] |
| 2nd | CHECK_FILE(file_b, "") | [file_b, file_c] |
| 3rd | CHECK_FILE(file_a, stash_a) | [file_a, file_b, file_c] |

Drain order: file_a → file_b → file_c. Each step makes the next one dirty before it runs.

---

### Stash Paths for Open Dependent Files

A subtle but important detail: open dependent files must be checked against their
**stash, not their on-disk content**. When a dependent file has unsaved changes (e.g. the
user edited file_c before saving), the on-disk content is stale. Checking against disk
content produces diagnostics for the wrong version of the file.

The stash path for any open file is:
```
storageDir / sha1(uri) & ".nim"
```

`storageDir` can be recovered from the changed file's own `q.dirtyFile` — since
`q.dirtyFile` is always `storageDir / sha1(changedUri) & ".nim"`, taking `parentDir(q.dirtyFile)`
gives `storageDir` without requiring it to be passed through every function signature.

Non-open intermediate files (file_b) have no stash and must be checked with `dirtyFile=""`
(on-disk content). This is correct because intermediate files are not open in the editor
and their on-disk content is always current.

---

### `chkFile` vs `chk` for Diagnostic Propagation

`chk` (CHECK_PROJECT / `ideChk`) calls `recompilePartially()` from the **project root** with
no specific file, then emits all entries in `suggestErrors`. This sounds like it should
propagate errors through the whole graph, but it does not, because:

1. It starts at the project root (`deps.nim`), which is not dirty → returns immediately
   without recompiling anything
2. Even if it did recompile, it only marks one hop of clients dirty per file recompiled

`chkFile` (CHECK_FILE / `ideChkFile`) calls `recompilePartially(moduleToCompile)` for a
**specific module**. When that module is sfDirty, recompilation runs and `markClientsDirty`
is called for that specific module. This makes `chkFile` the correct primitive for the
cascade — it gives fine-grained control over which module triggers the next hop of dirty
propagation.


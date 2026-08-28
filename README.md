
# Nim Tortoise

> *Slow and steady wins the race.*

> *...writing the code to make the tools to write the code...*

*NOTE: This repo is in active, heavy development.*

*NOTE: All other READMEs are a work in progress*

## What is it?

A fork and rewrite of [`nimlangserver`](https://github.com/nim-lang/langserver) and [`vscode-nim`](https://github.com/nim-lang/vscode-nim).

`Nim Tortoise` is a language server for the programming language `Nim`, and an accompanying VS Code extension.  The language server can act as a drop-in replace for [`nimlangserver`](https://github.com/nim-lang/langserver) for basic functionality or used with the accompanying VS Code Extension.

`Nim Tortoise` aims to prioritise correctness over speed.  In other words, it might work slower than the other nim language servers, but it will give you the correct information and not crash every 10 minutes.


## What's in This Repository

| Directory | What it is |
|-----------|------------|
| [`langserver/`](langserver/) | The Nim language server — a ground-up rewrite of `nimlangserver` |
| [`vscode_extension/`](vscode_extension/) | The VS Code extension — an LSP-only fork of `vscode-nim` |
| [`forest/`](forest/) | A Nim library for building dependency graphs across Nim projects. Used by `langserver`.  This also contains a collection of markdown files documenting the workings, quirks and idiosyncracies of the nim ecosystem that I discovered while rewriting the language server.  Maybe useful if you are attempting a similar type of project to this. |

The language server and VS Code Extension are designed to work together but are independent. The language server speaks standard LSP and will work with any LSP-capable editor.

You should be able to use `nimtortoise` as a drop-in replacement for `nimlangserver`, but I would recommend using the VS Code extension, as it removes many inefficiencies.  Note: The extension is written in Nim and compiled to JavaScript. It is not a TypeScript extension.

## Getting Started

### Requirements

- Nim with `nimsuggest` (`--v4` support, i.e. Nim 1.6+)
- `nimble >= 0.16.1`
- VS Code `>= 1.99.0` (for the extension)

Currently, I haven't set up the extension to automatically compile and use the nimtortoise server, so you'll have to build the server from source, store it somewhere, then build the extension, and set up the `settings.json` in your project to point the `"nimTortoise.lsp.path"` setting to the compiled `nimtortoise` binary.  

## To Use

### 1. Build the language server

```sh
cd langserver
nimble build      # produces the nimtortoise binary in `bin`
```

### 2. Build the VS Code extension

```sh
cd vscode_extension
nimble vsix            # packages out/vscode_nim_tortoise-<version>.vsix
```

### 3. Point the extension at the binary

Add to `.vscode/settings.json` in your project:

```json
{
  "nimTortoise.lsp.path": "/path/to/your/nimtortoise"
}
```

If omitted, the extension defaults to the `nimlangserver` server in `PATH`.

### 4. Install the VS Code Extension

Uninstall or disable any other Nim Language extensions, as they will conflict with `Nim Tortoise`.  Then, in VS Code, find your compiled `.vsix` file in the file explorer (it will be in the `vscode_extension/out` folder), right click on it, and choose `Install Extension VSIX`.

## Motivations: Why Rewrite?

I have been writing `nim` code since 2022 and have been coding with it daily since 2023.  At no point during this period has the combination of `nimlangserver` + `IDE` worked correctly for any of my projects.  Although I mainly use VS Code, I tried a number of different IDEs, with the same results.  I tried almost every possible configurtion of extension, IDE, and language server - with me eventually deciding to run the official VS Code Extension ([`vscode-nim`](https://github.com/nim-lang/vscode-nim)) with `nimsuggest` disabled, so I would get the text coloration but without it continuously rinsing my CPU at 100% for minutes at a time and destroying my battery-life.  

These were all inconveniences that I powered through because I enjoyed the language, and the downsides of IDE integration were much outweighed by the benefits of the progress I was making, 

Cut to July 2026, when the code base I am working in is over 100,000 lines of `nim` code in a monorepo with 30+ modules.  I load up this project in VS Code only for it to take 1 minute and 45 second of `nimble` running at 100% on my CPU before any aspect of the language server even works, and then, when it does, it manages to correctly give highlights and diagnostics for about 5-10 minutes before irretrievably crashing.  This forced progress on my work to become almost stationary.  So I decided to try and fix things.  

My first steps were to correct some low-hanging fruit that was causing bugs with the official `nimlangserver` language server (e.g. there was no code that dealt with the `textDocument/rename` request, meaning that if a file was moved or renamed, `nimsuggest` would have no idea, and nothing would work for that file or the rest of the project).  I made some similar fixes to the `vscode-nim` VS Code Extension, fixing the problem caused the 100% CPU spike at startup.  I made a few pull requests to the main repository with these fixesand, although I made progress, it still wasn't working _well_.  

I needed the language server to do the following things and, even with the fixes I still hadn't achieved this:

- Does not crash after only 10 minutes of use.
- Does not give incorrect diagnostic or hover infirmation.
- Gives correct, and up-to-date diagnostics and hover information for any file you have open in your IDE.
- Go-to definition works.  For the entirety of your session.  And for any file.
- Is not constantly rinsing the CPU.
- Respects the maximum number of nimsuggest processes I specify.

These are the aims of `Nim Tortoise`.  I will be the first to admit that I have not yet achieved all of these aims, but things work a lot better - and I'm actually getting some work done again! 

As I looked further into the [`nimlangserver`](https://github.com/nim-lang/langserver) code - and fixed the 15th race-condition-related bug - I realised that there were some architectural problems with the codebase that necessitated a complete rewrite...

The `Nim Tortoise` rewrite prioritises three things:

- Correctness > Speed: The information the language server provides about your code should always be correct and up-to-date.  At every point correctness will be picked over speed.  I don't mind having to wait an extra second if it means the that my IDE is going to show me information that is actually right and relevant.  This is more tortoise than hare.
- Stability: The language server should be stable- not  constantly crashing - I have work to do!
- Efficiency: The language server does have to deal with a lot of files, but it shouldn't be turning your laptop into a stellar-hot chunk while its working.  I aim for the language server to be CPU-light.  

This is done by having a strict First-In-First-Out queuing system for any request to the language server.  These requests are read one-at-a-time in order by a dispatcher which then routes them to the appropriate `nimsuggest` instance, each of which has its own First-In-First-Out queue.  The language server deals with how many instances of `nimsuggest` are running, spawns or removes instances from its "pool" and consolidates instances which share the same files, so the fewest instances possible are running at any one time.   `nimsuggest` is designed to crash if it cannot process a file, which means that care must be taken in handling exceptions so that the entire language server does not crash.  Finally, because of the queue system, it is possible to reduce the amount of work `nimsuggest` has to do by removing duplicate requests for the same file, limiting how frequently a file is `check`ed, and removing any requests in the queue that will be out-of-date because the file they are for has already changed (e.g. if the user is rapidly typing).

I am now using this tool daily and I hope it is helpful for other `nim` users. 

---
## v0.3.1

- "ctrl+alt+s" now triggers `check project`.  This will generate diagnostics for all files in the folder.

## v0.3.0

### nim check as fallback

If your code contains a critical error, like `SIGSEGV`, it is impossible to get `nimsuggest` to run on that code.  This is due to how `nimsuggest` uses the `nim` compiler internally, and anything with a critical compilation error causes a critical failure in `nimsuggest`.  However, you probably want some type of diagnostics _especially_ if you have errors in your project, so if `nimsuggest` encounters these types of errors, `Nim Tortoise` will temporarily use `nim check` to get diagnostics for your project, until the problem is fixed.

- **Status panel**: New tree-view panel in the VS Code sidebar showing live server status — nimsuggest pool health, open files, pending requests, and performance metrics
- **Nimsuggest crash diagnostics**: When nimsuggest crashes, the extension now automatically runs `nim check` on the affected file and surfaces compiler errors as standard LSP diagnostics
- **File deletion handling**: Deleting a tracked `.nim` file is now handled gracefully without leaving stale nimsuggest instances


## v0.2.0

### `projectMapping` is no longer required

You no longer need to use `projectMapping` in `settings.json` to get the language server to JSON to tell the language server which nimsuggest process should handle which file.  Instead, at launch, the server finds every nimble file in the folder and gets the appropriate `entryPoints`, `testEntryPoints` and `<srcDir>+<bin>` entryPoints used by `nimble` when it runs.  When a file is opened, entry point with the longest common path prefix to the opened file is selected — with a graceful fallback to the file itself if it turns out to be an "orphan" file not reachable from any entry point.

Previously, getting correct diagnostics in a multi-entry-point project required a manual `projectMapping` block in `.vscode/settings.json` that listed regex patterns mapping file paths to their project entry point. No more!

The `projectMapping` and `workingDirectoryMapping` settings have been removed entirely.

### Forest: a new dependency tree library

The automatic entry point discovery is powered by a new standalone library, `forest/`, that builds a complete import graph for a Nim project by combining `nim dump` and `nimble dump` metadata. On a 100,000-line codebase it completes in under one second.

The Forest is now used in two places:

- **Entry point selection** — routing each opened file to the correct nimsuggest slot (the fix for the missing diagnostics bug described below).
- **Transitive dependency updates** — when a file is saved, the server queries the Forest for every file that imports the saved file (directly or transitively) and sends re-check requests for all of them. Previously, only the directly importing files were updated; indirect dependents would continue to show stale diagnostics until the session was restarted.

The library ships with a comprehensive reference document (`forest/README.md`) covering every Nim project file type (`.nim`, `.nimble`, `nimble.paths`, `nimble.lock`, `nimble.develop`, `config.nims`, `.nims`, `nim.cfg`), how they relate to each other, and how the compiler resolves them.

## Fix: Updating dependencies

`Forest` has allowed a major set of bugs to be fixed that result from a particular `nimsuggest` quirk.  One problem I repeatedly encountered was as follows.  

Let's say I have `file_a.nim` with the following type:

```nim
# file_a.nim
type
    SpecialType* = object
        magical*: string
```

And I have `file_b.nim` that imports `file_a.nim` and uses its type:

```nim
# file_b.nim
import ./file_a.nim
let aVariableThatUsesAType = SpecialType(magical: "always")
```

And these both live in the same folder, and I have both of them open in a IDE, next to each other, editing them and looking at the diagnostics I receive back from the language server.  In the current state, there will be no errors.  But then, let's say, I change the type in `file_a.nim`, so that now `file_b.nim`'s usage of it is incompatible:

```nim
# file_a.nim
type
    SpecialType* = object
        magical*: int
```

The language server should give diagnostics to `file_b.nim` with a little red squiggly line and informing the user about a type incompatibility.  And it will - as long as `file_b.nim` directly imports `file_a.nim`.  

Now, when you change a file, you need to send a `changed` message to `nimsuggest` to tell it to update its knowledge of this file within its stored module graph.  The command looks like:

```
changed "/abs/path/to/file.nim";"/abs/path/to/dirtyfile.nim":0:0
```

When you send a `changed` message for `file_a.nim`, nimsuggest does mark `file_b.nim` as dirty — but only because `file_b.nim` directly imports `file_a.nim`. The propagation stops at one hop. So in the two-file case, this works correctly.

The problem arises with an intermediate file in the chain. Say we introduce `file_c.nim`:

```nim
# file_c.nim
import ./file_a.nim
export file_a
```

```nim
# file_b.nim
import ./file_c.nim
let aVariableThatUsesAType = SpecialType(magical: "always")
```

Now, if `file_c.nim` is closed (not being edited), and I change `file_a.nim` so that `magical` becomes `int`, nimsuggest receives `changed file_a` and marks `file_c` dirty — but stops there. `file_b.nim` is two hops away and is never marked dirty. Asking nimsuggest to check `file_b.nim` returns no errors, because it sees a clean cached result.

The fix is to walk the import chain and send a sequence of `chkFile` commands — not extra `changed` messages. Sending `changed` only marks a file dirty and clears its stored errors; it does not recompile. What actually triggers error propagation is recompilation, which happens when `chkFile` is called on a dirty file. Each `chkFile` recompiles that file and then marks its own direct importers dirty, setting up the next step:

1. `chkFile file_a ; stash_a` — recompiles `file_a` from the stash; marks `file_c` dirty
2. `chkFile file_c ; ""` — `file_c` is now dirty; recompiles it; marks `file_b` dirty
3. `chkFile file_b ; stash_b` — `file_b` is now dirty; recompiles it; error found

This langserver uses `forest` to find the intermediate files between the changed file and each open dependent, then queues this cascade of `chkFile` commands automatically whenever a file is edited.

### Performance Settinga

Because the language server is having to send more requests to `nimsuggest` this has created an increase in CPU usage.  In order to combat this, there is a new `performance` selector, found in the `Nim Tortoise` settings in VS Code.  Choose between `HIGHEST`, `HIGH`, `LOW` and `LOWEST` - each of which uses a different mix of request throttling and choosing when to save so you can better regulate where and when to allocate resources.  The `HIGHEST` setting checks and gives diagnostics back for any open dependencies on any change, meaning that this setting can be quite intensive.  `HIGH` is similar, but increases the amount of request throttling from a window of 250ms out to 1 second.  `LOW` also uses the same 1 second window, but will only update open files which are the dependencies of each other upon the user saving.  And `LOWEST` also uses the "only update dependencies upon saving" approach, but with a much larger request throttling window of 5 seconds.

### Missing diagnostics bug — fixed

In the previous release, diagnostics (errors, warnings, hints) were silently dropped for large numbers of files because each file was being routed to the wrong nimsuggest slot. The entry point selection logic used simple string heuristics that failed for projects with multiple entry points or non-standard directory layouts.

### Four queuing and dispatch bugs fixed

1. **Dead-slot query accumulation** — previously, `STOPPED` or `CRASHED` `nimsuggest` slots could still have messsages sent to them, creating futures that would never complete. It now returns immediately with an empty result for dead slots.
2. **`DID_CLOSE` deadlock** — previously, if a `nimsuggest` slot had stopped, the  close handler was awaiting a `CHECK_FILE` that could block indefinitely. `DID_CLOSE` is now fire-and-forget.
3. **Crash respawn loop** — previously, a freshly respawned `nimsuggest` slot could hang indefinitely because of `attemptCrashRespawn`.
4. **`DID_CHANGE` slot state check** — the change handler was enqueuing work without checking slot state first. Stopped or crashed slots now receive an immediate empty completion instead of accumulating orphaned futures.

### Other fixes

- **Timeout bug** — a timed-out nimsuggest query could leave the slot in an inconsistent state, causing all subsequent queries to that slot to also time out.
- **Multiline comment autocomplete** — fixed incorrect closing token insertion when the cursor was inside a multiline comment block.
- **Accidental restarts from configuration updates** — the server was restarting the full nimsuggest pool on every `workspace/didChangeConfiguration` notification, even when the incoming values were identical to what was already configured. An `isDifferentFrom()` comparison now suppresses no-op restarts.
- **Stash not cleared on save** — `DID_SAVE` now correctly tells nimsuggest to stop reading from the temporary stash file and revert to the on-disk version. Previously, hover and diagnostics after a save continued to show pre-save buffer content until the session was restarted.
- **Gensym and `:anonymous` highlights** — compiler-internal symbol names (`:anonymous`, `:result`, `:tmp`, backtick-suffixed gensyms from macro expansion) were causing highlights to be the wrong length and misaligned.  These names are now filtered or cleaned up before being passed to the client.

### Other additions

- **More readable type mismatch messages for procs** — a new formatter (`utils/type_mismatch_format.nim`) decomposes complex type mismatch errors for `proc`s into readable parameter-by-parameter lists, handling nested generics, optional types, and parameters with default values.
- **Dependency checking at startup** — the server now verifies, at startup and on each file open, that a file is actually reachable from its project entry point. Orphaned files (not imported by anything) are flagged and handled gracefully rather than causing silent failures downstream.
- **Formalised extension protocol** — extension capabilities (`RestartSuggest`, `NimbleTask`, `RunTests`) and nimsuggest capabilities (`con`, `exceptionInlayHints`, `unknownFile`) are now defined in `protocol/extensions.nim` rather than scattered as magic strings.
- **`.vscode/settings.json` namespace** — all settings entries have been switched from the `nim.` prefix to `nimTortoise.` to prevent conflicts when `nimlangserver` or `vscode-nim` are also installed.
- Internal refactoring (81 files changed).  Including splitting the single 1,198-line `protocol/types.nim` into seven focused modules, extracting LSP handlers into per-domain modules and creating separate dispatcher files for `textDocument/didOpen` and `textDocument/didChange`.
- **Warning errors when nimsuggest thinks the same types are different** 

```
Error: type mismatch
Expression: newCodeLensProvider(
✗  [1] `seq[VscodeCodeLens]` should be `seq[VscodeCodeLens]`
)
Note: nimsuggest may be registering the same type as two distinct types due to an internal module graph inconsistency. Consider restarting nimsuggest.nim(nimsuggest chk)
```

### Removal of Exception Inlay Hints

During writing this version, I discovered a bug where, on certain types of files (maybe ones with an extensive use of generics, templates and/or macros - it's unclear to me...), passing the flag `--exceptionInlayHints:on` to nimsuggest will cause it to catastrophically spiral into an infinite loop that eats up 100% CPU and never terminates.  For this reason, this setting is always set to OFF and can never be toggled on.  For simpler types of files, this setting also seems to contribute to much longer startup times.  

---

## Problems

What follows is a catalogue of the problems in the original `nimlangserver` + `vscode-nim` combination that the rewrite is designed to fix.

### The extension/server split

The most pervasive structural problem was that the boundary between the VS Code extension and the language server was never cleanly drawn. The extension contained its own direct nimsuggest integration — its own TCP socket management, its own query dispatch, its own `nimble dump` invocation — running in parallel with whatever the language server was doing. The result was two independent agents both issuing commands to the same nimsuggest process with no coordination between them.

In practice this meant:

- `setNimDir` in the extension ran `nimble dump` on every activation, before the language server even started. The language server then ran `nimble dump` again from its `initialized` handler. Both were talking to different versions of nimble with different PATH environments, and neither result was shared with the other.
- Language features (hover, completion, go-to-definition, diagnostics, inlay hints) had separate handler implementations in both the extension and the server — fifteen or more modules doing work that the LSP protocol already defines a standard channel for.
- State was duplicated. The extension and the server each tracked their own understanding of which files were open and which nimsuggest processes existed. These could diverge silently.

### Startup and configuration timing

Nimsuggest was spawned from the `initialize` handler, before any workspace configuration had been requested from the client. This meant `projectMapping`, `maxNimsuggestProcesses`, and all other routing rules were empty at spawn time. Processes were started with default settings and the configuration that arrived later was ignored or only partially applied.

The more painful variant of this: VS Code launched from the Dock (macOS) inherits a minimal `PATH` that does not include `~/.nimble/bin`. The extension found an older Homebrew nimble instead of the user's current version. That older nimble could not resolve Nim 2.x packages from the local cache and fell back to its exponential-time SAT solver (`findMinimalFailingSet`). The result was `nimble` running at 100% CPU for over a minute before the language server could do anything at all.

Mock launching in the Dock it using: 

```env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" nimble dump```

Even when nimble was found correctly, it was sometimes invoked with an absolute path passed as an argument when it expected a relative one, producing silently empty output. `entryPoints`, `nimDir`, and `srcDir` all came back as empty strings, and the server continued as though nothing had gone wrong.

A further timing problem: `withTimeout` on the workspace configuration future would cancel the shared future when the timeout expired. All other coroutines waiting on the same future lost their waiter simultaneously. The configuration that eventually arrived was never received by any of them.

### Nimsuggest imports and the cold-compilation problem

Nimsuggest was launched without the `--path:` flags generated by `nimble setup`. Without those flags, its internal compiler had to resolve every import by calling nimble itself — invoking the SAT solver on each one. For a project with many dependencies, cold-compilation took over 50 seconds. With `nimble.paths` correctly forwarded, the same compile took 10–15 seconds.

The working directory was also not set correctly for nimsuggest spawns. Without being pointed at the project root, nimsuggest could not find `config.nims` and its per-subpackage `--path:` entries, compounding the import resolution failures.

### Race conditions and concurrency

This is the largest category of bugs and the one that made patching futile — each fix exposed another race underneath it.

**No ordering guarantee on requests.** Handlers in many different parts of the codebase could call nimsuggest concurrently. A `didChange` stash write and the hover query that followed it could be interleaved arbitrarily. Nimsuggest would answer the hover against the old buffer content, and the user would see stale information with no error or indication that anything was wrong.

**Two incompatible dispatch paths coexisted.** The original TCP dispatch in `suggestapi.nim` was called directly from route handlers. A queue system existed alongside it but was not wired up — `checkFile` and `tryGetNimsuggest` both bypassed it. The queue ran in parallel with the direct dispatch, issuing duplicate commands to the same nimsuggest connection.

**`OrderedSet` mutation during iteration SIGSEGV.** `removeIdleNimsuggests` iterated `ns.openFiles` at the same time as `didCloseFile` mutated it. Nim's set implementation aborts with a SIGSEGV when the length changes mid-iteration. This was a reliable crash path for sessions with many short-lived files.

**Concurrent `didOpen` for the same URI.** The guard `if uri in ls.openFiles` was checked before any `await`. After the first `await` point, a second coroutine processing the same URI could pass the same guard. The second assignment would overwrite the first's completed `projectFile` future, leaving the file tracked against the wrong nimsuggest instance.

**Spawn limit bypass.** Three separate code paths spawned nimsuggest instances without checking `maxNimsuggestProcesses`: the project mapping match path, `initNimsuggestInstances`, and `getNimsuggestInner`. Concurrent `didOpen` handlers all observed count=0 before any spawn completed, so all of them would spawn — regardless of the configured limit.

**`errorCallback` cascade.** When `warnIfUnknown` deliberately stopped a nimsuggest process, in-flight TCP commands failed and fired `errorCallback`. That callback, not knowing the stop was intentional, treated it as a crash and automatically restarted the killed instance. This put the intentional shutdown and the automatic restart in competition with each other.

**Failed spawn sentinel blocks re-spawn permanently.** `createOrRestartNimsuggest` inserted a sentinel future into the process table before the first `await`. If the spawn then failed, the `except` clause logged the error but did not delete the sentinel. The pending future stayed in the table indefinitely. Every subsequent request for that project would wait 33 seconds (three retries × increasing backoff) before giving up — a silent, permanent hang.

**`didCloseFile` KeyError via stale `ns.openFiles`.** `ns.openFiles` was populated on `didOpen` but never cleared on `didClose`. After many open/close cycles, the set accumulated stale URIs. `cancelPendingFileChecks` iterated this set and crashed with `Table.[missing_key]` when it tried to look up a file that had long since been closed.

**Double write on a Future.** During slot eviction, pending queries were drained by completing their `responseFuture` with `@[]`. At the same time, `processNimsuggestQueries` might also be completing the same futures with real results. Writing to a Future twice violates Chronos's single-write invariant and produces undefined behavior.

### Crash recovery

Crash recovery was distributed across several subsystems — `crashedFiles`, `project.failed`, `project.errorCallback`, and auto-restart logic all lived in different files — and none of them told a consistent story.

When `execSpawn` caught a `CatchableError`, it set `state = CRASHED` and stopped. There was no automatic respawn. The slot stayed dead indefinitely. The only path back to a working nimsuggest was an explicit `RESTART` command issued from outside, which was itself stubbed.

When a crash did trigger auto-restart, there was no backoff. The restart was queued immediately. If the underlying cause (bad binary, missing file, bad config) persisted, the server entered a tight spin loop retrying at full CPU speed until `MAX_CRASH_RETRIES` was exhausted.

After a crash and respawn, only the file that triggered the crash was re-registered with the new nimsuggest process. All other open files were lost — nimsuggest had no knowledge of them and would return empty results for any query involving those files.

Evicted slots were never removed from `pool.slots`. After `EVICT_AND_SPAWN` sent `STOP`, the dead slot remained in the table as an idle shell. With many file opens over a long session, the table grew without bound.

### Position encoding

The LSP protocol uses 0-based line numbers and UTF-16 code-unit columns. Nimsuggest expects 1-based line numbers and UTF-8 byte columns. These coordinate systems agree for ASCII-only files and diverge for anything containing non-ASCII characters.

The original code did not perform this conversion correctly. `toUtf8Col` was called at query dispatch time, not at query creation time. Between creation and dispatch, a `didChange` could update the fingerTable for the file. The old position was then resolved against the new fingerTable, producing a wrong column. For files with Unicode identifiers, emoji in strings, or multi-byte comments, highlights and hover targets would point to the wrong locations in the source.

Compiler-internal symbol names were passed through unmodified to the IDE: `:anonymous`, `:result`, `:tmp`, `:env`, `:iterator`, `:objectType` (compiler-generated gensyms that never appear in source), and backtick-mangled names like `procName\`gensym0` (produced by template/macro expansion). These appeared verbatim in hover tooltips and completion lists, making it impossible to know which source token they corresponded to.

### Stash and save semantics

The stash mechanism — writing unsaved buffer content to a temporary file so nimsuggest can check in-progress edits — had two important bugs.

First, the stash path was derived using `hash(uri).toHex`, a 64-bit hash. Two different URIs with the same hash would silently corrupt each other's edit buffer. Hover and diagnostics would show the wrong content without any error.

Second, `didSave` did not tell nimsuggest to stop using the stash and revert to the on-disk file. Hover and diagnostics after a save continued to reflect the pre-save in-memory stash content until the session was restarted. Similarly, `checkFile` did not call `changed()` before `chkFile()`, so nimsuggest checked the stale cached AST from the previous save rather than the current buffer.

### Missing handlers

Several LSP notifications had no handler at all:

- **`workspace/didRenameFiles`**: entirely absent. After a file was renamed or moved, nimsuggest's module graph still referenced the old path. The next query triggered `getModule(fileIndex)` returning nil, `incl m.flags, sfDirty` on the nil module, and a SIGSEGV. The stash file was also left at the old path, and `openFiles` retained the stale URI. Hover, completion, and inlay hints stopped working for the renamed file and any file that imported it.
- **`workspace/didChangeConfiguration`**: incomplete. Changes to `nimsuggestIdleTimeout`, `projectMapping`, and hints settings were silently ignored. A full language server restart was required for any configuration change to take effect.
- **`extension/suggest` (restart action)**: stubbed. Users had no manual recovery path after a persistent crash.

### Nim check and nimsuggest running in parallel

The original codebase used both `nim check` and `nimsuggest` for diagnostics, depending on settings. When both were active, they ran concurrently against the same files, producing duplicate or contradictory diagnostic sets. `nim check` also added full compiler invocations on every save, contributing to the CPU spikes at startup and after edits.

## Improvements

### Architecture: the dispatcher and queuing model

All LSP work flows through a strict two-level pipeline. The diagram below shows the complete path from an IDE action to a nimsuggest response.

```mermaid
flowchart TD
    IDE[VS Code]
    LQ([langserverQueue\nFIFO])
    D{Dispatcher}
    FA[File operations\ninline]

    IDE -->|LSP| LQ --> D
    D -->|didOpen/Change/Save| FA

    subgraph Pool[NimsuggestSlot Pool]
        MB1([mailbox A\nFIFO]) --> NS1[nimsuggest A]
        MB2([mailbox B\nFIFO]) --> NS2[nimsuggest B]
    end

    D -->|queries| MB1
    D -->|queries| MB2
```

The key invariant: a `DID_CHANGE` stash write **always** completes before the hover (or any other nimsuggest query) that follows it, because both pass through the same FIFO `langserverQueue` in arrival order. Only after the file work is done does the nimsuggest query land in the slot's mailbox.

### VS Code extension pruned to an LSP-only wrapper

The original `vscode-nim` combined a VS Code extension with its own direct nimsuggest integration — approximately 4,764 lines of bespoke TCP protocol, elrpc RPC, flatDB local database, and 15+ language-feature modules, all talking to nimsuggest independently of whatever the language server was doing.

The rewrite strips all of that out. The extension is now ~270 lines of pure LSP client. Every language feature — hover, completion, go-to-definition, diagnostics, inlay hints, macro expansion, ARC expansion — comes from the language server over the standard LSP protocol. The extension's only job is to start the server and relay messages. No nim compiler, no nimsuggest socket, no nimble invocation ever runs inside the extension process.

### Startup performance

Startup is around 10–15 seconds for a 100,000+ line monorepo on a 2019 MacBook. The previous combination took over a minute before any language features were available (and often crashed before the minute was up).

Two changes drive this improvement: the extension now runs `nimble setup` automatically on first activation if `nimble.paths` is absent (generating all search paths in one fast pass, bypassing the SAT solver on every subsequent launch), and `nimble dump` results are cached per `.nimble` file so the expensive SAT solve only happens once per session.

`~/.nimble/bin` is prepended to the environment of every child process, ensuring `nim`, `nimble`, and `nimsuggest` are found regardless of how VS Code was launched (GUI launch vs. terminal launch differ in the `PATH` they inherit)

### Correctness through serialisation

One of the primary causes of incorrect information in the old codebase was that many parts of the code could issue nimsuggest queries concurrently — racing each other to read from and write to the same TCP connection, producing stale responses, incorrect highlights, and occasional crashes.

The rewrite imposes a strict ordering guarantee via the two-level queue described above:

1. A single **FIFO `langserverQueue`** serialises every file operation and every nimsuggest request. A `didChange` stash write is guaranteed to complete before the hover query that follows it — no exceptions.
2. Each nimsuggest process has its own **per-slot `queryMailbox`**. Commands for the same process are serialised; commands for different processes run concurrently and independently.

### Stable process ownership

The old architecture tracked file-to-project ownership in two separate tables that had to be kept in sync by convention at every mutation site. The rewrite replaces this with a single `NlsFileInfo.slot` direct reference: each open file points directly to its `NimsuggestSlot`, and each slot owns a `HashSet` of URIs. There are no redirect aliases, no manual sync, no guards to check.

### Robust crash recovery

- Exponential backoff between restart attempts (1 s → 2 s → 4 s → … capped at 30 s)
- User notification via `window/showMessage` after repeated failures; the dead slot is removed from the pool rather than retried forever
- Correct re-registration of **all** open files after a restart, not just the file that triggered it
- No more infinite crash loops pegging the CPU

### Nimsuggest process pool

- Strictly enforces the `maxNimsuggestProcesses` limit via LRU eviction — slots in states `STOPPED` or `CRASHED` are evicted first, then `STOPPING`, then the least-recently-used `READY` slot
- **Consolidation**: when a newly spawned slot's nimsuggest already knows about files held by an existing slot, all those URIs are migrated to the new slot and the old one is torn down — no redundant processes
- Entry-point slots (discovered via `nimble dump`) are pre-spawned before the first `DID_OPEN`, so most files are handled immediately

### Accurate UTF-16 ↔ UTF-8 position translation

VS Code (and the LSP protocol) addresses positions as 0-based line numbers with UTF-16 code-unit columns. Nimsuggest expects 1-based line numbers with UTF-8 byte columns. These two coordinate systems diverge for any file containing non-ASCII characters.

The rewrite builds a **fingerTable** for every open file — a per-line mapping from UTF-16 code-unit offsets to UTF-8 byte offsets — regenerated on every `DID_CHANGE`. All nimsuggest queries convert through this table before dispatch. The original code did not perform this conversion, so highlights were always wrong for files containing Unicode identifiers, string literals with emoji, or multi-byte comments.

Additionally, compiler-internal symbol names are now handled correctly:

- **Colon-prefix gensyms** (`:anonymous`, `:result`, `:tmp`, `:env`, `:iterator`, `:objectType`) — these never appear in source and are filtered or displayed appropriately
- **Backtick-gensym suffixes** (e.g. `procName\`gensym0`) — the suffix added by template/macro expansion is stripped; only the source token before the backtick is shown

### Query deduplication and CPU throttling

Previously, every keystroke could fire a cascade of inlay-hint, document-symbol, hover, and diagnostic queries simultaneously, saturating the nimsuggest TCP connection and driving CPU usage to 90–99% during active editing.

The per-slot query processor now applies two layers of deduplication before dispatching anything:

- **Background queries** (`INLAY_HINTS`, `DOCUMENT_SYMBOLS`): dropped if a `CHANGED` query is pending in the mailbox or if the file was edited within `fileCheckDelay` milliseconds (default: 1000 ms)
- **Position queries** (`SUGGEST`, `HOVER`, `SIGNATURE_HELP`, etc.): dropped if a newer query of the same kind for the same URI is already queued, or if a `CHANGED` is pending

This brought observed CPU usage from 90–99% during editing down to under 25% for the same workload.

### Save semantics fixed

`DID_SAVE` now sends a `CHANGED` query with an empty `dirtyFile` parameter, explicitly telling nimsuggest to stop reading from the stash file and revert to the on-disk version. In the original code this step was absent, so hover and diagnostics after a save continued to reflect the pre-save in-memory content until the session was restarted.

Transitive dependencies are also handled: when a file is saved, nimsuggest re-checks all files that import it, propagating changes across module boundaries correctly.

### Monorepo support

Entry point routing is now handled automatically by the Forest (see 0.1.4 release notes). The language server discovers every `.nimble` file in the workspace, runs `nim dump` on each entry point, and routes each opened file to the correct nimsuggest instance without any manual configuration. The former `projectMapping` and `workingDirectoryMapping` settings have been removed.

- **`nimTortoise.test.entryPoints`**: array of test entry points (one per sub-project) for the test runner, falling back to the singular `test.entryPoint` for single-project repos

---

## Known Limitations

### Stubbed features

- **Macro expansion** (`extension/macroExpand`): always returns null. The "Expand Macro" hover action in VS Code produces no output.

I have rewritten the extension and language server to focus on doing one thing well:

- Giving correct information back to the IDE from the language server.

This has meant removing some functionality.  What has been removed:

- Test running: To get the information about what tests are running, the tests need to successfully compile using the nim compiler.  This causes big CPU spikes upon launching the IDE while it gets the test, and it will only succeed if the tests compile.  If I open up an IDE, why do I want to add extra wait time to an already slow startup procedure.
- MCP functionality: I decided to not support this until I can get the language server running correctly and robustly.
- Using `nim check` for checking files - everything now uses `nimsuggest`.
- Using `nimsuggest` rather than the full language server - this was a setting in `nimlangserver` but resulted in a lot of duplicated work.

---

## All Settings Use `nimTortoise.`

This extension uses the `nimTortoise.` prefix for all settings and commands to avoid conflicts with the original `vscode-nim` extension. The two **cannot be installed simultaneously** — this extension replaces the original.

Key settings at a glance:

| Setting | Default | What it does |
|---------|---------|--------------|
| `nimTortoise.transportMode` | `"stdio"` | Transport to connect to the language server (`stdio` or `socket`) |
| `nimTortoise.lsp.path` | `""` | Path to the language server binary (falls back to `nimlangserver` in PATH) |
| `nimTortoise.performance` | `"HIGH"`  | Sets performance mode. `HIGHEST`, `HIGH`, `LOW`, `LOWEST`.  `HIGHEST` is most CPU intensive but most responseive and accurate. |
| `nimTortoise.formatOnSave` | `false` | Format with `nph` on save (if `nph` is installed). |
| `nimTortoise.nimsuggestPath` | `"nimsuggest"` | Path to the nimsuggest binary |
| `nimTortoise.nimsuggestSpawnTimeout` | `60` | Timeout in seconds before stopping a nimsuggest process if it is spawning. |
| `nimTortoise.maxNimsuggestProcesses` | `2` | Max nimsuggest processes (0 = unlimited) |
| `nimTortoise.maxNimsuggestCrashRetries` | `3` | Restart attempts before a crashed nimsuggest is abandoned |
| `nimTortoise.nimsuggestIdleTimeout` | `1800` | Idle timeout in ms before stopping a nimsuggest process |
| `nimTortoise.inlayHints.typeHints.enable` | `false` | Show inferred type annotations |
| `nimTortoise.inlayHints.parameterHints.enable` | `false` | Show parameter name hints |
| `nimTortoise.nimExpandMacro` | `false` | Expand macro calls on hover (TODO) |
| `nimTortoise.nimExpandArc` | `false` | Expand ARC on proc definition hover (TODO) |

---

## Acknowledgements

This project builds on the work of:

- The [nimlangserver](https://github.com/nim-lang/langserver) team
- [@saem](https://github.com/saem) for [vscode-nim](https://github.com/saem/vscode-nim)
- [@kosz78](https://marketplace.visualstudio.com/items?itemName=kosz78.nim) for the original TypeScript Nim extension

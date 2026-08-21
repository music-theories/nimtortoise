# The Nim Compiler

This document covers the Nim compiler (`nim`) as it relates to language server
development: how it resolves imports, how packages are structured, what NimCache
does, and where it is slow.

For configuration file search order (`nim.cfg`, `config.nims`, `nimble.paths`), see
[configs.md](configs.md). For `--noNimblePath` and the nimble package path system,
see [nimble.md](nimble.md).

---

## Overview

The Nim compiler (`nim`) is a source-to-C (or JS, or other backends) compiler. For
language server purposes, the most important facts are:

- **`nimsuggest` embeds the Nim compiler** — it is not a separate tool; nimsuggest
  compiles your project using the same logic as `nim c`, but in-process. Any behaviour
  documented here for `nim c` also applies to nimsuggest.
- **`nim c` vs `nim check`**: `nim c` compiles and links; `nim check` compiles and type-
  checks without producing output. This langserver does not use `nim check` — everything
  goes through nimsuggest for consistency.
- **Version coupling**: nimsuggest must be the same version as nim. They share AST node
  layouts, type system internals, and stdlib. A mismatch causes silent failures or crashes.

```bash
nim --version | head -1
nimsuggest --version | head -1
# Must match. If they differ, your PATH is routing to binaries from different installations.
```

---

## Import Resolution Algorithm

Understanding import resolution is essential for setting up `config.nims` correctly and
for diagnosing "cannot open file" errors.

Given a search path entry `D` and the statement `import foo/bar`, Nim checks:

1. `D/foo/bar.nim` — single-file submodule
2. `D/foo/bar/bar.nim` — directory-aggregator pattern (directory named same as file)

The **first match wins**. Nim does not continue searching after the first match.

Search path entries are checked in order:
1. Explicitly passed `--path:` entries (left to right)
2. Nim standard library (always on path; `--noNimblePath` does not remove it)
3. `~/.nimble/pkgs2/` and `~/.nimble/pkgs/` (unless `--noNimblePath` is active)

**Implication**: `--noNimblePath` removes only the nimble cache from the search path —
the stdlib remains available. Standard modules (`strutils`, `os`, `posix`, etc.) are
always found.

**Implication**: Two packages with the same module name — one in `--path:`, one in
`~/.nimble/pkgs2/` — will always resolve to the `--path:` version. This is the intended
behaviour when using `nimble.paths`.

### Diagnosing missing imports

`nim dump` outputs the full resolved search path:

```bash
nim dump --dump.format:json src/forest.nim
```
---

## The Double-Naming Convention

Nim packages in a monorepo often follow a specific layout that determines how imports work.

```
mypackage/               ← package root (contains .nimble and config.nims)
  mypackage.nimble
  config.nims
  src/
    mypackage.nim        ← entry point; aggregator; imports and re-exports everything below
    mypackage/           ← subdirectory named the same as the package
      submodule_a.nim
      submodule_b/
        submodule_b.nim  ← aggregator: imports and re-exports parts.nim, utils.nim
        parts.nim
        utils.nim
```

When another package adds `mypackage/src` to its search path:

```nim
import mypackage             # resolves to src/mypackage.nim (top-level entry)
import mypackage/submodule_a # resolves to src/mypackage/submodule_a.nim
import mypackage/submodule_b/submodule_b  # resolves to src/mypackage/submodule_b/submodule_b.nim
```

**Why the double naming**: Without it, `import mypackage/submodule_b` would look for
`src/mypackage/submodule_b.nim` (a file) — which works for single-file submodules, but
breaks when `submodule_b` expands into a multi-file directory. The aggregator pattern
(`submodule_b/submodule_b.nim`) keeps callers from needing to know which submodules are
single-file vs multi-file.

**Gotcha**: A flat `submodule_b.nim` file alongside a `submodule_b/` directory takes
precedence over the directory. If you switch from single-file to multi-file layout,
delete the old flat file first.

### The top-level entry point

`src/mypackage.nim` is often an aggregator — it imports and re-exports all public
submodules and contains no logic of its own. This is what nimsuggest is given as its
root: by importing the entry point, it sees the entire package.

```nim
# src/mypackage.nim
import ./mypackage/submodule_a
import ./mypackage/submodule_b/submodule_b
export submodule_a, submodule_b
```

---

## NimCache

NimCache is Nim's incremental compilation cache. It stores compiled `.nim.c` (and
`.nim.c.o`) artifacts from previous runs.

- **Location**: `~/.cache/nim/` (Linux/macOS)
- **Effect on startup**: A warm NimCache reduces nimsuggest cold-compile time from ~25s
  to ~11s (with `--path:` flags). Without NimCache, every session starts from zero.
- **Persistence**: Survives VS Code restarts and system reboots
- **Shared**: The cache is shared between `nim c` builds and nimsuggest instances

### When to clear NimCache

Clear after:
- Significant refactors (stale `.nim.c` artifacts from renamed/moved files remain)
- Package renames or directory moves
- Compiler flag changes (`passC`, `passL`, `define` flags)
- Symbol corruption: completions return symbols that no longer exist, or go-to-definition
  points to wrong locations
- Unexplained "identifier not found" errors that disappear after a clean build

Clearing is always safe — the cache rebuilds automatically on the next nimsuggest spawn
or `nim c` invocation.

### `getattrlist` Polling (macOS Cold Cache Tail)

On macOS, the last several seconds of a cold nimsuggest startup are dominated by
repeated `getattrlist` system calls on the entry-point file:

```
getattrlist  /path/to/project/src/nimtortoise.nim  (tens of thousands of repetitions)
```

The compiler polls the entry point for modification during the final code-emission phase.
With no NimCache, every poll is a cold filesystem hit. This is normal — not a hang — and
disappears on subsequent starts once NimCache is warm.

---

## Generics, Macros, and Compilation Cost

### Generic instantiation

The Nim compiler instantiates a separate copy of a generic proc for each distinct set of
type parameters. A codebase heavily using `Future[T]` (as chronos-based code does) creates
hundreds of `Future` instantiations. Each instantiation:

- Allocates new `PType`/`PSym` objects
- Runs through type checking, overload resolution, and code generation independently
- Triggers mark-and-sweep GC cycles (nimsuggest is compiled with `--gc:markAndSweep`)

The `resolveOverloads → pickBestCandidate → matches` cycle in the compiler's semantic
analysis phase runs hundreds of times for a large async codebase — each `await`/`Future`
overload resolution is a separate instance.

**This is not a hang** — it is genuinely expensive work that terminates correctly. On a
warm NimCache, the results are reused. On a cold cache, this accounts for most of the
25-second compilation time.

### Macros and templates

Macros expand at compile time and can generate additional generic code. Each expansion
can trigger new generic instantiations, which compounds the cost. Templates are inlined
at call sites and have similar effects.

Heavy use of macros, templates, and generics is the combination that causes
`--exceptionInlayHints:on` to hang — see [nimsuggest.md](nimsuggest.md) for the full
analysis.

### Effect inference (`raises` sets)

Each proc's `raises` effect set is computed by walking the call graph. For generic procs,
a separate `raises` set must be computed for each instantiation. This is normally fast,
but on deeply nested generic hierarchies with errors in the code (which prevent
convergence), the inference can loop. This is the root cause of the
`--exceptionInlayHints:on` hang.

---

## `nim dump`

`nim dump <file>` outputs the compiler's view of the compilation environment for that
file: search paths, defined symbols, Nim version, and system paths.

```bash
nim dump --dump.format:json src/forest.nim

nim dump src/mypackage.nim
```

Useful for diagnosing:
- Missing import paths (compare against what `config.nims` declares)
- Wrong nim version being used
- Whether `nimble.paths` is being included (look for the `--path:` entries)
- Which `config.nims` files are being read

---

## Version Notes

### Nim 2.x vs 1.x

The langserver targets Nim 2.x. Key differences relevant to the language server:

- **ORC memory management** (default in 2.x): tail-recursive async procs accumulate
  Future allocations indefinitely (each tail call creates a new closure that is freed
  only when the chain resolves — for an infinite loop, never). Always use
  `while true: await sleepAsync(...)` instead of tail recursion in async code.

### Nim 2.2.x

The development target. Nim 2.2.4 is the version observed during the rewrite
investigations. Chronos 4.x (the async library used by this langserver) requires Nim 2.x.

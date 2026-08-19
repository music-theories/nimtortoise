# Nim Configuration Files

Nim has three overlapping configuration mechanisms: `nim.cfg` (declarative), `config.nims`
(NimScript), and per-file `.nims` files. They interact in ways that are not clearly
documented and that cause a class of hard-to-debug errors in multi-package repositories.

This document covers all three, plus `nimble.paths`, the `thisDir()` vs `$projectDir`
distinction, and the transitive dependency rule.

---

## Overview

| File | Syntax | When processed | Scope |
|---|---|---|---|
| `nim.cfg` | Declarative | First, before config.nims | Directory and ancestors |
| `config.nims` | NimScript (full Nim subset) | After nim.cfg | Directory and ancestors |
| `.nims` | NimScript | Last | Single `.nim` file only |
| `nimble.paths` | nim.cfg flags | Via include in config.nims | Project dependencies |

---

## Configuration Search Order

For each module it compiles, the Nim compiler:

1. Starts from the **entry point file** (not the module being compiled)
2. Walks up the directory tree to the filesystem root
3. At each directory, reads `nim.cfg` then `config.nims` (if they exist)
4. Reads the per-file `.nims` for the specific `.nim` file being compiled (if it exists)

**Global configs** (read first, before the directory walk):
- `~/.config/nim/nim.cfg`
- `~/.config/nim/config.nims`

The per-module `.nims` is the only config read from the module's own directory. All
other configuration comes from the entry point's directory ancestry.

### The critical rule: library config files are ignored

**A library's own `config.nims` is never read when that library is imported by another
package.** Only the `config.nims` files in the ancestry of the **top-level entry point**
are read.

See [The Transitive Dependency Rule](#the-transitive-dependency-rule) below for the full
consequences and concrete examples.

---

## `nim.cfg`

`nim.cfg` uses a declarative syntax with `@if`/`@end` conditionals. It is processed
before `config.nims` in the same directory.

### Syntax

```
# Comments start with #
--path:"relative/or/absolute/path"
--define:myFlag

@if windows:
  --path:"windows/specific/path"
@end

@if posix:
  --passL:"-lpthread"
@end
```

### When to use `nim.cfg` vs `config.nims`

- **`nim.cfg`**: Platform conditionals, compiler flags, linker flags; anything that needs
  to be processed before NimScript evaluation
- **`config.nims`**: Dynamic logic, conditional includes, `switch()` calls, task definitions

In practice, most projects use `config.nims` exclusively unless they need `@if`
conditionals that depend on the target platform at config-read time.

---

## `config.nims`

`config.nims` is a NimScript file — a restricted subset of Nim that runs at compile time
to configure the compilation environment.

### Key NimScript procs

```nim
switch("path", "/absolute/or/relative/path")   # add to search path
switch("define", "myFlag")                     # define a symbol
switch("passC", "-I/usr/include/mylib")        # pass flag to C compiler
switch("passL", "-lmylib")                     # pass flag to linker
switch("opt", "speed")                         # optimization level
```

### Standard config.nims template

This template is the recommended starting point for any Nim package:

```nim
# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Add sibling packages to the search path.
# thisDir() = the directory containing this config.nims file.
switch("path", thisDir() & "/../other_package/src")
switch("path", thisDir() & "/../../shared/libs/src")
```

The `--noNimblePath` line prevents the global nimble package cache (`~/.nimble/pkgs2/`)
from interfering. Without it, a stale installed version of a package you are actively
developing can silently shadow your local changes.

The `when withDir(...)` block includes `nimble.paths` if it exists. This is the standard
nimble workflow — `nimble setup` generates `nimble.paths` and `config.nims` auto-includes
it. The `withDir` wrapper is necessary because `fileExists` resolves relative to the
current working directory at config-evaluation time, not relative to `config.nims`.

---

## `thisDir()` vs `$projectDir`

This is the single most important distinction in `config.nims`. Getting it wrong causes
nimsuggest to fail to find sibling packages for files in subdirectories, even though
everything works correctly at the package root.

| Expression | Resolves to |
|---|---|
| `thisDir()` | The directory containing the `config.nims` file — **always correct** |
| `$projectDir` | The directory containing the `.nim` file currently being compiled — **changes** |

### Why `$projectDir` is wrong

Consider a package `model/api/` with this layout:

```
model/api/                   ← config.nims lives here
  config.nims
  src/
    api/
      api.nim                ← the file being compiled
```

With `$projectDir`:
```nim
switch("path", "$projectDir/../funis/src")
# When api.nim is compiled:
# $projectDir = model/api/src/api/
# Resolves to: model/api/src/api/../funis/src
#            = model/api/src/funis/src       ← WRONG, does not exist
```

With `thisDir()`:
```nim
switch("path", thisDir() & "/../funis/src")
# thisDir() = model/api/    (always, regardless of which file is being compiled)
# Resolves to: model/api/../funis/src
#            = model/funis/src               ← CORRECT
```

### When `$projectDir` and `thisDir()` are equivalent

Only when `.nim` files are in the same directory as `config.nims` — for example, a
`tests/config.nims` where all test `.nim` files live immediately alongside it. Even in
this case, prefer `thisDir()` for consistency and safety.

### Always use `thisDir()`

**Rule**: All `switch("path", ...)` calls in package-level `config.nims` files must use
`thisDir()`, not `$projectDir`.

---

## `nimble.paths`

`nimble.paths` is generated by `nimble setup`. It is not a NimScript file — it uses the
same declarative syntax as `nim.cfg`, but is `include`d from `config.nims`.

### Format

```
--noNimblePath
--path:"/absolute/path/to/chronos/src"
--path:"/absolute/path/to/json_rpc/src"
--path:"/absolute/path/to/stew/src"
```

One `--path:` line per package dependency, using absolute, content-addressed paths into
`~/.nimble/pkgs2/`.

### Properties

- **Gitignored** by design — paths are absolute and machine-local; cannot be committed
- **Must be regenerated** by each developer after cloning: `nimble setup`
- **Content-addressed** — if you change a locked dependency version, `nimble.paths` must
  be regenerated; the old paths will still exist in `~/.nimble/pkgs2/` but will point
  to the old version

### When `nimble.paths` is missing

If `nimble.paths` does not exist:
- The `when withDir(thisDir(), system.fileExists("nimble.paths"))` block is skipped
- The Nim compiler must resolve package imports via the nimble registry scan
- This adds thousands of filesystem operations and 15+ seconds of overhead
- Imports may resolve to wrong package versions (both installed; compiler picks first match)

**Fix**: `cd /path/to/project && nimble setup`

### The `--noNimblePath` effect

The first line of `nimble.paths` is `--noNimblePath`. This tells the Nim compiler:
- Do not scan `~/.nimble/pkgs2/` for packages
- Do not scan `~/.nimble/pkgs/` (legacy)
- Only use explicitly passed `--path:` entries and the standard library

Combined with explicit `--path:` entries from `nimble.paths`, this eliminates:
- The pkgs2 directory scan (hundreds of `open` syscalls for unrelated packages)
- Wrong-version package probing (both `chronos-4.0.4` and `chronos-4.0.5` appearing)
- The `posix.nim` resolution explosion (failing through all packages before finding stdlib)

See [performance.md](performance.md) for measured filesystem operation counts.

---

## Per-File `.nims` Files

A `.nims` file with the same name as a `.nim` file applies configuration only to that
specific file:

```
src/
  mymodule.nim
  mymodule.nims    ← applies only to mymodule.nim
```

This is rarely used in practice. Most configuration belongs in `config.nims` at the
package root. Per-file `.nims` is useful for:
- File-specific compiler flags (e.g. `-d:useMalloc` for a specific module)
- File-specific search paths that would conflict with the rest of the package

---

## The Transitive Dependency Rule

This is the most confusing aspect of Nim's config system and the source of a class of
errors that appear to come from inside a library but are actually missing from the
top-level package.

### The rule

**A library's `config.nims` is used only when the library is itself the entry point.**
When the library is imported from a top-level package, only the top-level package's
ancestor `config.nims` files are read. The library's own `config.nims` is invisible
from the top-level build.

Consequence: if package A imports package B, and package B imports package C, then the
**top-level entry point's `config.nims`** must declare search paths for A, B, and C.

```
entry.nim
  → imports A  (declared in entry's config.nims ✓)
      → imports B  (must ALSO be in entry's config.nims ✓)
            → imports C  (must ALSO be in entry's config.nims — easy to miss)
```

### A concrete example

`save_system/src/save_system/save_trees/save_tree_types.nim` contains:
```nim
import routing
```

`model/save_system/config.nims` declares:
```nim
switch("path", thisDir() & "/../routing/src")   # ← routing is resolvable here
```

This means `routing` is found when `nim c` is invoked with `save_system` as entry point.

Now consider two top-level builds:

**Build 1 — server (succeeds):**
```bash
nim c model/server/src/server.nim
```
`model/server/config.nims` includes:
```nim
switch("path", thisDir() & "/../routing/src")
```
When `server.nim` imports `save_system`, and `save_tree_types.nim` tries to `import routing`,
the path entry is in scope. ✓

**Build 2 — client (fails):**
```bash
nim c controller/client/src/client.nim
```
`controller/client/config.nims` adds `model/save_system/src` but NOT `model/routing/src`:
```nim
switch("path", thisDir() & "/../../model/save_system/src")  # ← save_system found
# model/routing/src is NOT here
```
`save_system/config.nims` is never read. When the compiler reaches `save_tree_types.nim`
and sees `import routing`:
```
Error: cannot open file: routing
```
The error appears to come from inside `save_system`, but the problem is in
`client/config.nims`.

### The fix

Add the missing path to the top-level package's `config.nims`:
```nim
# controller/client/config.nims
switch("path", thisDir() & "/../../model/routing/src")   # ← add this
```

### Why this is easy to miss

When adding a new import to a shared library, you update the library's `config.nims` and
the library's own tests pass. Every other top-level package that imports the library
silently inherits the new transitive dependency — and fails only when someone actually
builds it. The failure message points into the middle of the library, not at the
top-level package where the fix belongs.

**Rule of thumb**: Every time you add a new package dependency to a library's
`config.nims`, also add it to the `config.nims` of every top-level package that imports
the library.

### How to find what's missing

1. `Error: cannot open file: X` — X is the missing module
2. Find the package: `find . -name "X.nim" -not -path "*/\.*"`
3. Add to the failing top-level `config.nims`:
   ```nim
   switch("path", thisDir() & "/relative/path/to/package/src")
   ```
4. Verify: `nim dump src/entry.nim 2>&1 | grep "lib\|path"` — the new path should appear

---

## How nimsuggest Finds `config.nims`

When the langserver spawns nimsuggest, it sets `workingDir` to the nimble project root.
The Nim compiler embedded in nimsuggest performs the same ancestor walk from the entry
point file. If the working directory is set correctly, the walk will find `config.nims`
in the project root.

---

## Debugging Configuration Issues

### See the full resolved search path

```bash
nim dump --dump.format:json src/forest.nim
```

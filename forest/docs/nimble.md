# Nimble

Nimble is Nim's package manager. This document covers its role in language server
development, its command-line tools, the many subtle ways it can behave unexpectedly,
and how this langserver works around those behaviours.

---

## Overview

Nimble manages:
- The `.nimble` file format (package manifests)
- The `~/.nimble/pkgs2/` package cache
- Dependency resolution (SAT solver)
- Package download and installation
- Build task execution (`nimble build`, `nimble test`, custom tasks)

For language server purposes, the two most important things nimble does are:
1. `nimble dump` — produces metadata the langserver reads at startup
2. `nimble setup` — generates `nimble.paths`, which is passed to nimsuggest

---

## The `.nimble` File Format

A `.nimble` file is a NimScript file with a specific set of package metadata variables.  Below is a comprehensive list of fields specified in the current version:

From https://nim-lang.github.io/nimble/nimble-reference.html

### `[Package]` — Required

| Field | Description |
|---|---|
| `name` | Package name (not required in NimScript format) |
| `version` | Current version; increment before tagging a release |
| `author` | Author name |
| `description` | Human-readable description |
| `license` | License identifier (e.g. `MIT`) |

### `[Package]` — Optional: Installation filtering

"Installation" here means **when someone else installs your package** — via `nimble install your-pkg` or as a dependency of their project. Nimble copies files from your repo into a local cache (typically `~/.nimble/pkgs/`). The `skip*` and `install*` fields control which files are included in that copy.

`skip*` fields are a blacklist: exclude these, copy everything else. `install*` fields are a whitelist: copy only these (plus the `.nimble` file and any declared binary). The two sets cannot be combined — use one approach or the other.

Common use: add `skipDirs = @["tests", "docs", "examples"]` so consumers don't download files they'll never use.

| Field | Description |
|---|---|
| `skipDirs` | Directory names to exclude from installation (comma-separated) |
| `skipFiles` | File names to exclude from installation (comma-separated) |
| `skipExt` | File extensions to exclude, without leading `.` (comma-separated) |
| `installDirs` | Directories to exclusively install; nothing else is installed except these, `installFiles`, `installExt`, the `.nimble` file, and any binary |
| `installFiles` | Files to exclusively install (complements `installDirs` and `installExt`) |
| `installExt` | Extensions to exclusively install (complements `installDirs` and `installFiles`) |

### `[Package]` — Optional: Build configuration

| Field | Type | Description |
|---|---|---|
| `srcDir` | `string` | Directory containing `.nim` source files. **Default:** the directory containing the `.nimble` file (project root). Must be a bare string literal: `srcDir = "src"`. |
| `binDir` | `string` | Directory where `nimble build` writes compiled binaries. **Default:** project root |
| `bin` | `seq[string]` | Executables to build (no extension). Makes this a binary package. **Must use `@[...]` syntax**: `bin = @["myapp"]`. A bare string `bin = "myapp"` is invalid and will not be parsed correctly. |
| `namedBin` | `seq[string]` | Like `bin` but with explicit output names: `name:value`. Overrides duplicates in `bin` |
| `backend` | `string` | Compiler backend for `bin` targets: `c`, `cc`, `cpp`, `objc`, or `js`. **Default:** `c` |
| `paths` | `seq[string]` | Relative paths added to `nimble.paths` and the compiler's search path. Covers the same ground as `--path:` in `nim.cfg` but declared in the package manifest |
| `entryPoints` | `seq[string]` | Relative paths to `.nim` files used by nimlangserver as project entry points. Useful for test aggregator files such as `tall.nim`. **Must use `@[...]` syntax**: `entryPoints = @["src/main.nim"]`. |
| `testEntryPoint` | `string` | Relative path to the test file containing imported tests (e.g. `tall.nim`). **Default:** `""` (empty; if unset, Nimble discovers test files automatically) |

## An average .nimble file

```nim
# Package metadata
version     = "1.0.0"
author      = "Your Name"
description = "What this package does."
license     = "MIT"

# Source layout
srcDir      = "src"

# Executables
bin         = @["myapp", "anotherapp"]

# Entry Points
entryPoints = @["src/entrypoints/abandon_hope.nim"]
testEntryPoint = "tests/test.nim"

# Dependencies
requires "nim >= 2.2.0"
requires "chronos >= 4.0.0"

# Tasks
task dev, "Build and run in development mode":
  exec "nim c -r -o:bin/myapp src/myapp.nim"
```

## How does `nimble` determine an `entryPoint`?

There are multiple ways that `nimble` determines an entry point, using examples from the sample file above:

1. Use the `entryPoints` field. 
  - e.g. `src/entrypoints/abandon_hope.nim`
2. `srcDir` + `bin`: Concatenate these two fields and add `.nim` on the end.  These are then added onto the internal entryPoints variable, even if the `entryPoints` field.
  - e.g. `@["src/myapp.nim", "src/anotherapp.nim"]`.  
3. Use the `testEntryPoints` field. 
4. If `srcDir` is empty, the project root is used.  So, if there was no `srcDir` set in the example above, the result would be `@["myapp.nim", "anotherapp.nim"]`.

Some worked examples using the forest.nimble file:

```nim
srcDir        = "src"
```

```json
{ 
  "entryPoints": [
    "src/forest.nim"
  ],
  "testEntryPoint": ""
}
```
---

```nim
bin           = @["forest"]
```

```json
{
  "entryPoints": [
    "forest.nim",
    "forest.nim"
  ],
  "testEntryPoint": ""
}
```
---
```nim
srcDir        = "src"
bin           = @["forest"]
```

```json
  "entryPoints": [
    "src/forest.nim",
    "forest.nim"
  ],
  "testEntryPoint": ""
```
---

```nim

```

```json
{
  "entryPoints": [
      "forest.nim"
    ],
  "testEntryPoint": ""
}
```
---
```nim
srcDir        = "src"
bin           = @["forest"]
entryPoints   = @["src/forest.nim"]
testEntryPoint = "tests/tdependency_tree.nim"
```
```json
{
  "entryPoints": [
    "src/forest.nim",
    "src/forest.nim",
    "forest.nim"
  ],
  "testEntryPoint": "tests/tdependency_tree.nim"
}
```

## `nimble dump`

`nimble dump` extracts metadata from a `.nimble` file and prints it in a parseable format. The langserver reads the output to learn: package name, source directory, entry points, and dependencies.


### What `nimble dump` outputs

Relevant fields parsed by the langserver:

| Field | Example | Notes |
|---|---|---|
| `name` | `nimtortoise` | Package name |
| `version` | `0.1.0` | Package version |
| `srcDir` | `src` | Source directory (default: `""`) |
| `bin` | `nimtortoise` | Named executables |
| `entryPoints` | `src/nimtortoise.nim` | Computed as `srcDir / bin[i] & ".nim"` |
| `requires` | `nim >= 2.2.0, chronos >= 4.0.0` | Dependency constraints |

The langserver parses `entryPoints` from the dump output line:
```nim
if line.startsWith("entryPoints"):
  result.entryPoints =
    line[(1 + line.find '"') ..^ 2].split(',').mapIt(it.strip(chars = {' ', '"'}))
```

### Time a `nimble dump` call

```bash
time nimble dump
```

---

## `nimble setup` and `nimble.paths`

`nimble setup` (also triggered implicitly by `nimble develop` in some versions) generates
a `nimble.paths` file in the project root. This file contains:

```
--noNimblePath
--path:"/Users/dp/.nimble/pkgs2/chronos-4.0.4-e4bebd.../src"
--path:"/Users/dp/.nimble/pkgs2/json_rpc-0.5.0-.../src"
--path:"/Users/dp/.nimble/pkgs2/websock-0.2.0-.../src"
--path:"/Users/dp/.nimble/pkgs2/stew-0.2.0-.../src"
--path:"/Users/dp/.nimble/pkgs2/chronicles-0.10.3-.../src"
--path:"/Users/dp/.nimble/pkgs2/bearssl-0.2.5-.../src"
--path:"/Users/dp/.nimble/pkgs2/regex-0.26.1-.../src"
```

### Properties of `nimble.paths`

- **Absolute paths** — machine-local; cannot be committed to version control
- **Content-addressed** — directory names embed content hashes; changing a package version
  changes the directory name
- **Gitignored** by design — every developer must run `nimble setup` after cloning
- **Auto-included** by `config.nims` — the standard config.nims template includes
  `nimble.paths` automatically when it exists

### Why `nimble.paths` matters so much

Without `nimble.paths`, the Nim compiler embedded in nimsuggest must resolve every package
import through the nimble registry scan — opening every directory in `~/.nimble/pkgs2/`,
probing wrong-version packages, and traversing ancestor directories searching for
`config.nims`. This adds 30,000+ filesystem operations and ~15 seconds of overhead.

With `nimble.paths`, the compiler knows exactly where each package lives. One filesystem
stat per import, no registry scan, no wrong-version probing. See
[performance.md](performance.md) for measured filesystem counts.

### How the langserver uses `nimble.paths`

The langserver reads `nimble.paths` via `findNimblePaths`, which:
1. Walks up from the project file directory looking for `nimble.paths`
2. Extracts `--noNimblePath` and `--path:...` entries
3. Strips surrounding quotes
4. Passes these flags directly to nimsuggest at spawn time

This ensures the correct paths are applied even if nimsuggest's working directory is
not the project root (where `config.nims` might otherwise auto-include `nimble.paths`).

---

## `nimble.lock`

`nimble.lock` pins all dependency versions to exact content-addressed hashes. When present,
`nimble install` and `nimble setup` use the pinned versions rather than resolving
constraints afresh.

This prevents "works on my machine" dependency drift but means `nimble.paths` paths are
stable across machines (same hashes → same directory names in `~/.nimble/pkgs2/`).

---

## `nimble.develop`

`nimble.develop` specifies local overrides for development: packages that are in active
development locally and should be used from their local path instead of from the nimble
cache. Useful when simultaneously editing a library and its consumers.

---


### Never call with an explicit path argument

```bash
# WRONG — triggers the SHA1 storm (74 seconds on a medium project):
nimble dump /path/to/project
nimble dump .

# CORRECT — fast (1-5 seconds):
nimble dump   # run from the project directory
```

When `nimble dump` receives an explicit path argument, it calls `getPackageByPattern` to
identify which package lives at that path. This calls `calculateDirSha1Checksum`, which
reads **every file** in the project directory recursively to compute a content fingerprint.
Then `solutionToFullInfo` runs the same procedure on every resolved dependency package
in `~/.nimble/pkgs2/`. On a project with many dependencies, this results in 64,000+
filesystem operations and 74 seconds of wall time.

Without a path argument, `nimble dump` reads the `.nimble` file in the current working
directory directly. There is no `getPackageByPattern`, no directory scan, no SHA1 storm.

**Correct invocation in code:**
```nim
let result = startProcess(
  command = nimblePath,
  workingDir = nimbleFile.parentDir,   # ← set working dir to project root
  args = @["dump"],                    # ← no path argument
  options = {poUsePath},
)
```


---

## Nimble Tasks

`.nimble` files can define custom tasks:

```nim
task dev, "Build and run in development mode":
  exec "nim c -r -o:bin/myapp src/myapp.nim"

task test, "Run all tests":
  exec "nim c -r --path:. tests/all.nim"
```

The langserver exposes these via `extension/tasks` (the nimble tasks panel in VS Code).
Internally, it calls `nimble tasks` to list them and `nimble <taskname>` to run them.

Before running nimble tasks, the langserver clears `NIMBLE_DIR` from the environment to
avoid conflicts with any overridden nimble locations.

---

## Spawning Nimble from a path on mac

When VS Code is **launched from the macOS Dock**, the child processes can inherit a restricted PATH:

```
/usr/bin:/bin:/usr/sbin:/sbin
```

This can cause a number of problems.  In this case, shell profile scripts (`~/.zshrc`, `~/.bashrc`, etc.) are not sourced and the `export PATH="$HOME/.nimble/bin:$PATH"` line in your shell config is absent.

This can cause problems if nimble has been installed via two different means at different times in your system's history.  For instance, for me, I had an older version of nimble left over from a earlier installation via `homebrew`, as well as a more recent version.  Because the spawned shell inherited a restricted PATH, the version spawned via VS Code was a different version to that spawned normally from my terminal:

On my machine, querying `nimble`'s version from an environment simulating a  Dock-launch on MacOS with PATH restrictions ...

```bash
env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" \
  nimble -v
# -> nimble v0.18.2 compiled at 2025-04-22 02:00:42
```
... gives a different result to the same query with a non-restricted PATH

```bash
nimble -v
# ->nimble v0.22.2 compiled at 2026-07-02 14:52:12
```

... this can obviously cause a number of problems and mismatches

**Fix in the server**: Always resolve the nimble binary path explicitly.

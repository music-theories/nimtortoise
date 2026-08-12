
# Nim Tortoise

> *Slow and steady wins the race.*

*NOTE: This repo is in active, heavy development.*

*NOTE: All other READMEs are a work in progress*

## What is it?

A fork and rewrite of [`nimlangserver`](https://github.com/nim-lang/langserver) and [`vscode-nim`](https://github.com/nim-lang/vscode-nim).

This is a language server for the programming language `Nim`, and an accompanying VS Code extension.  The language server can act as a drop-in replace for `nimlangserver` for basic functionality or use it with the VS Code Extension.

The language server aims to prioritise correctness over speed.  In other words, it might work slower than the other nim language servers, but it will give you the correct information and not crash every 10 minutes.

## Motivations: Why Rewrite?

I have been writing `nim` code since 2022 and have been coding with it daily since 2023.  At no point during this period has the combination of `nimlangserver` + `IDE` worked correctly for any of my projects.  Although I mainly use VS Code, I tried a number of different IDEs, with the same results.  I tried almost every possible configurtion of extension, IDE, and language server - with me eventually deciding to run the official VS Code Extension with `nimsuggest` disabled, so I would get the text coloration but without it continuously rinsing my CPU at 100% for minutes at a time and destroying my battery-life.  

These were all inconveniences that I powered through because I enjoyed the language, and the downsides of IDE integration were much outweighed by the benefits of the progress I was making, 

Cut to July 2026, when the code base I am working in is over 100,000 lines of `nim` code in a monorepo with 30+ modules and.  I load up this project in VS Code only for it to take 1 minute and 45 secondd of `nimble` running at 100% on my CPU before any aspect of the language server even works, and then, when it does, it manages to correctly give highlights and diagnostics for about 5-10 minutes before irretrievably crashing.  This forced progress on my work to become almost stationary.  So I decided to try and fix things.  

My first steps were to correct some low-hanging fruit that was causing bugs with the official `nimlangserver` language server (e.g. there was no code that dealt with the `textDocument/rename` request, meaning that if a file was moved or renamed, `nimsuggest` would have no idea, and nothing would work for that file or the rest of the project).  I made some similar fixes to the `vscode-nim` VS Code Extension, fixing some problems involving placing extra guards to ensure no more `nimsuggest` processes were spawned than the user wanted, and fixing the 100% CPU at startup problem, which was the result of both VS Code not supplying the correct `PATH` information for the programs it spawned in the shell, nor correct configuration information for those programs when they ran, `nimble`'s SAT solver to kick-in because it wasn't being directed to the correct folder.  I made a few pull requests to the main repository and, although I made progress, it still wasn't working _well_.  

I basically needed the language server to do the following things:

- Does not crash after only 10 minutes of use.
- Does not give incorrect diagnostic or hover infirmation.
- Gives correct, and up-to-date diagnostics and hover information for any file you have open in your IDE.
- Go-to definition works.  For the entirety of your session.  And for any file.
- Is not constantly rinsing the CPU.
- Respects the maximum number of nimsuggest processes I specify.

These are the aims of Nim Tortoise.

Looking further at the code - and trying to fix the 15th race-condition-related bug - I realised that there were some architectural problems with the code base that necessitated a complete rewrite...

In this rewrite I prioritise three things:

- Correctness > Speed: The information the language server provides about your code should always be correct and up-to-date.  At every point correctness will be picked over speed.  I don't mind having to wait an extra second if it means the that my IDE is going to show me information that is actually right and relevant.  This is more tortoise than hare.
- Stability: The language server should be stable- not  constantly crashing - I have work to do!
- Efficiency: The language server does have to deal with a lot of files, but it shouldn't be turning your laptop into a stellar-hot chunk while its working.  I aim for the language server to be CPU light.  

## Problems

There were a number of reasons `nimlangserver` was not working for a lot of people (especially those using VS Code).  These problems are a combination of:
 
- An inelegant split between the responsibilities of the VS Code extension, and those of the language server
- The language server not waiting for configuration information before initializing.
- `PATH` information not being properly used or dissemintated to processes running in VS Code.  In the original VS Code extension, there was a problem that could cause the extension to run `nimble` at 100% for over a minute.  It would run `nimble dump` unconditionally on activation with an empty or incorrect `projectFile`/`entryPoint` parameter, causing it to search in vain for a `.nimble` file, fail to find it, and generally spiral as its exponential-time SAT solver kicked-in.
- Notifications and requests were being passed to `nimsuggest` from many different parts of the code base, resulting in out-of-date information, duplicate and stale requests, and race conditions.

## Nim Tortoise

I have rewritten the extension and language server to focus on doing one thing well:

- Giving correct information back to the IDE from the language server.

This has meant removing some functionality.  What has been removed:

- Test running: To get the information about what tests are running, the tests need to successfully compile using the nim compiler.  This causes big CPU spikes upon launching the IDE while it gets the test, and it will only succeed if the tests compile.  If I open up an IDE, why do I want to add extra wait time to an already slow startup procedure.
- MCP functionality: I decided to not support this until I can get the language server running correctly and robustly.
- Using `nim check` for checking files - everything now uses `nimsuggest`.
- Using `nimsuggest` rather than the full language server - this was a setting in `nimlangserver` but resulted in a lot of duplicated work.

## Improvements

### VS Code Extensionn never does more than necessary

Many of the problems I was experiencing were happening as a result of an imperfect split of responsibilities between the VS Code extension and the Language Server.  In the rewrite, the VS Code Extension is pruned back to being the thinnest wrapper possible around the language server.  Any use of the `nim` compiler, `nimsuggest` or `nimble` is dealt with by the language server - the only aim of the extension is to route information between the IDE and the server.  Previously, any nunmber of executables were spawned by the extension (often with incorrect or incomplete information).

### Startup performance

Startup performance is around 10-15 seconds for this repository on my 2019 macbook.

### Correctness through serialisation

One of the major causes for incorrect information was related to the fact that many different parts of the code base could request, mutate or read from key pieces of information with very little care being taken as to whether the actions were being processed in the correct order, or whether duplicate (and superfluous) messages were queued.

All LSP work flows through a two-level queue:

1. A single **FIFO `langserverQueue`** serialises all file and nimsuggest work. A `didChange` stash write is always applied before the hover query that follows it — no exceptions.
2. Each `nimsuggest` process has its own **per-slot `queryMailbox`**. Commands for the same process are serialised; commands for different processes run concurrently.

This eliminates the race conditions (stale responses, crashes, incorrect highlights) caused by concurrent handlers sharing the same TCP connection to nimsuggest.

### Stable process ownership

The old architecture tracked file-to-project ownership in two separate tables that had to be kept in sync by convention at every mutation site. The rewrite replaces this with a single `NlsFileInfo → slot` reference: each open file points directly to its `NimsuggestSlot`, and each slot owns a set of URIs. There are no redirect aliases, no manual sync, no guards to check.

### Robust crash recovery

- Exponential backoff between restart attempts (1s → 2s → 4s → … capped at 30s)
- User notification after repeated failures, with the dead slot removed from the pool
- Correct re-registration of all open files after a restart, not just the one that triggered it
- No more infinite crash loops at full CPU

### Nimsuggest processes

- Strictly abide by the `maxNimsuggestProcesses` limit,
- Consolidation mechanism - multiple nimsuggest instances with be consolidated into one instance if either imports the other's project file.

## What's in This Repository

| Directory | What it is |
|-----------|------------|
| [`langserver/`](langserver/) | The Nim language server — a ground-up rewrite of `nimlangserver` |
| [`vscode_extension/`](vscode_extension/) | The VS Code extension — an LSP-only fork of `vscode-nim` |

The two components are designed to work together but are independent. The language server speaks standard LSP and will work with any LSP-capable editor.

You should be able to use `nimtortoise` as a drop-in replacement for `nimlangserver`, but I would recommend using the VS Code extension, as it removes many inefficiencies.

### Correctness in General

- The VS Code LSP stores line and character information as 0-based lines and Utf16 characters.
- Nimsuggest expects 1-based lines and Utf8 characters.\
- This results in the use of `fingerTables` to convert between the two.
- The original repo would always incorrectly convert nimsuggest responses to LSP positions.
- Highlighting would always be wrong for certain types of code:
  - Colon-prefix (compiler-internal, never appear in source):
    - `:anonymous` — lambda/closure procs
    - `:result` — implicit result variable
    - `:tmp` — compiler temporaries
    - `:env` — closure environments
    - `:iterator` — iterator state
    = `:objectType` — object type internals
  - Backtick-gensym (source token exists, name is mangled):
    - e.g. "procName\`gensym0" — the \`gensymN suffix is added by template/macro expansion. The source token is just everything before the backtick.

## Getting Started

### Requirements

- Nim with `nimsuggest` (`--v4` support, i.e. Nim 1.6+)
- `nimble >= 0.16.1`
- VS Code `>= 1.99.0` (for the extension)

### Build the language server

```sh
cd langserver
nimble build      # produces the nimtortoise binary
```

### Build and install the VS Code extension

```sh
cd vscode_extension
nimble vsix            # packages out/vscode_nim_tortoise-<version>.vsix
nimble install_vsix    # installs it into VS Code
```

The extension is written in Nim and compiled to JavaScript. It is not a TypeScript extension.

### Point the extension at the binary

Add to `.vscode/settings.json` in your project:

```json
{
  "nimTortoise.lsp.path": "/path/to/your/nimtortoise"
}
```

Currently, I haven't set up the extension to automatically compile and use the nimtortoise server, so you'll have to build the server from source, using `nimble build`, store it somewhere, then build the extension, and set up the `settings.json` in your project to point the "nimTortoise.lsp.path" setting to the compiled `nimtortoise` binary.  This will be fixed in later versions.

If omitted, the extension defaults to the `nimlangserver` server, and  searches `~/.vscode-nim-tortoise/nimbledeps/bin/nimlangserver` then `nimlangserver` in `PATH`.

---

## All Settings Use `nimTortoise.`

This extension uses the `nimTortoise.` prefix for all settings and commands to avoid conflicts with the original `vscode-nim` extension. The two **cannot be installed simultaneously** — this extension replaces the original.

Key settings at a glance:

| Setting | Default | What it does |
|---------|---------|--------------|
| `nimTortoise.lsp.path` | `""` | Path to the language server binary (falls back to `nimlangserver` in PATH) |
| `nimTortoise.nimsuggestPath` | `"nimsuggest"` | Path to the nimsuggest binary |
| `nimTortoise.maxNimsuggestProcesses` | `2` | Max nimsuggest processes (0 = unlimited) |
| `nimTortoise.maxNimsuggestCrashRetries` | `3` | Restart attempts before a crashed nimsuggest is abandoned |
| `nimTortoise.nimsuggestIdleTimeout` | `120000` | Idle timeout in ms before stopping a nimsuggest process |
| `nimTortoise.projectMapping` | `[]` | Per-file project mapping via regex |
| `nimTortoise.workingDirectoryMapping` | `[]` | Override the working directory used when running nimsuggest for a given project |
| `nimTortoise.checkOnSave` | `false` | Run project-wide diagnostics on save |
| `nimTortoise.fileCheckDelay` | `1000` | Quiet period in ms after last edit before per-file diagnostics run |
| `nimTortoise.formatOnSave` | `false` | Format with `nph` on save |
| `nimTortoise.inlayHints.typeHints.enable` | `true` | Show inferred type annotations |
| `nimTortoise.inlayHints.parameterHints.enable` | `true` | Show parameter name hints |
| `nimTortoise.inlayHints.exceptionHints.enable` | `true` | Show exception inlay hints |
| `nimTortoise.nimExpandMacro` | `false` | Expand macro calls on hover |
| `nimTortoise.nimExpandArc` | `false` | Expand ARC on proc definition hover |
| `nimTortoise.transportMode` | `"stdio"` | Transport to connect to the language server (`stdio` or `socket`) |

Full settings reference is in [vscode_extension/README.md](vscode_extension/README.md).

---

## Documentation

- [langserver/README.md](langserver/README.md) — how nimsuggest and the language server work together, best practices for project setup, architecture details
- [vscode_extension/README.md](vscode_extension/README.md) — full settings reference, commands, debugging setup, test runner, development guide

---

## Acknowledgements

This project builds on the work of:

- The [nimlangserver](https://github.com/nim-lang/langserver) team
- [@saem](https://github.com/saem) for [vscode-nim](https://github.com/saem/vscode-nim)
- [@kosz78](https://marketplace.visualstudio.com/items?itemName=kosz78.nim) for the original TypeScript Nim extension

# v0.3.2 is now out

This will probably be the last update for a while, now that `Nim Tortoise` is at a stage of stability, correctness and performance that I am happy with.  Now I need to use it to actually do some work on the code I'm supposed to be writing!

I thought I'd provide a summary of the project, some of its differences to `nimlangserver` and `vscode-nim`, and some of the things I learned along the way, in case anyone attempts something similar in the future.  

## Stability

One of the main reasons for rewriting `nimlangserver` was the fact that it kept crashing nearly every 5-10 mins on the large code base I was working on.  I am happy to say `Nim Tortoise` is much more stable, thanks to a number of changes:

### Handling Crashes

Fundamentally, in 2026, a Language Server for nim is essentially a baby-sitter for (an often very unruly) set of `nimsuggest` instances.  Part of this responsibility means ensuring that crashes by `nimsuggest` are handled gracefully and that there are fallbacks in place to ensure that, unless in the most dire circumstances, a user is never without some type of diagnostics about their code.  `Nim Tortoise` has a three step process to running `nimsuggest` on a project:

1. Try and run the project from the entry point of the project, specified in the related `.nimble` file.  If `nimsuggest` crashes ...
2. Try spawning `nimsuggest` using the file the user has open as the entry point.  If `nimsuggest` crashes ...
3. Use `nim check` on the open file to give the user diagnostics.  Try and respawn `nimsuggest` when the user saves (presumably they have corrected the errors).

This fallback to `nim check` is especially important as, if your code that triggers a crash in nimsuggest's internal compiler (e.g., via a `SIGSEGV` in nimsuggest itself), it is impossible to get `nimsuggest` to run on that code.  Ironically, you probably want some type of diagnostics _especially_ if you have these type of errors in your project.  `nim check` will return diagnostics even if the code contains critical errors.

If a `nimsuggest` instance crashes while the user is using it, upon saving the file, the same 3-stage spawn approach listed above is used.

### Shutting down

Similarly, if a nimsuggest instance needs to be closed, care must be taken to ensure all aync `future`s are correctly completed or cancelled and the main `nimsuggest` process and its sub-processes are properly exited and do not hang or keep running in the background.  `Nim Tortoise` pays special attention to ensuring all `nimsuggest` processes are quit properly and that timeouts are abided by.

### Large Code Bases

`Nim Tortoise` aims to be suitable and stable for working in monorepos or large code bases.  I have tested it on large repos like the main nim compiler repo and `constantine`.  Even when a crash occured, it was handled gracefully, and the respawn mechanism worked.  

### Monorepos

`Nim Tortoise` does not need a special `projectMapping` section in the user's settings in order to find the correct entry points to spawn `nimsuggest` instances from.  Instead, it traverses all files and folders in the project you are working on, and uses `nimble` to automatically extract the entry points and test entry points for that module.  If you open a file in that module, `Nim Tortoise` will find the correct project entry point and spawn `nimsuggest` from there.  

### Exception Inlay Hints

One big discovery was that, on certain types of files (maybe ones with an extensive use of generics, templates and/or macros - it's unclear to me...), passing the flag `--exceptionInlayHints:on` to nimsuggest will cause it to catastrophically spiral into an infinite loop that eats up 100% CPU and never terminates.  For this reason, in `Nim Tortoise`, this setting is always set to OFF and can never be toggled on.  For simpler types of files, this setting also seems to contribute to much longer startup times.  

### Process ownership

In the `vscode-nim` VS Code extension, instances of `nimble`, `nim` and `nimsuggest` were being spawned from both the language server and the extension, leading to a cross-cutting of concerns and, in some cases, bugs related to whether or not a spawned process had the correct PATH information.  In `Nim Tortoise`, all control of processes is given to the language server. The VS Code Extension becomes a thin mediator between the VS Code client and language server and is only responsible for spawning the language server itself, not other nim-related processes.

## Correctness

### Dispatch and Queuing

I think one of the reasons for incorrect diagnostics in `nimlangserver` was due to race conditions resulting from many different types of requests and notifications being able to directly query a `nimsuggest` instance at any time.  `Nim Tortoise` solves this by implementing a dispatcher and queuing system to ensure that all commands get sent to the correct `nimsuggest` instance, and are then executed in the correct order.

### Renaming or moving files 

One of the problems seen in `nimlangserver`, was that it was missing an endpoint for `textDocument/didRenameFiles` (this is corrected in one of the pull requests I made to `nimlangserver` a few weeks ago).  This notification is sent by the IDE when a file is moved or renamed through the editor's interface. Without it, `nimsuggest` does not get updated information about the location and state of the moved files, leading to crashes.  `Nim Tortoise` ensures there is code to handle all commonly-used endpoints in the LSP spec (including `workspace/didChangeConfiguration`).  Additionally the endpoints of `Nim Tortoise` better conform to the LSP spec.

### Utf8 <-> Utf16 conversion 

There is a disconnect between `nimsuggest`'s internal representation of the line and column numbers in a file and those used in the LSP spec.  

- `nimsuggest`
  - line: 1-based
  - column: UTF8
- `lsp`
  - line: 0-based
  - column: UTF16

This means that at every point at which `nimsuggest` and the `LSP` share position data within a file, care must be taken to ensure that the correct format is used.  `Nim Tortoise` does this by using nim's type system to catch these types of errors at compile time.

### Transitive dependencies

This was one of the most difficult problems to solve, and I imagine it might be one of the most common that people see when they say that the "language server isn't working".  To give an example:

Let's say I have `file_a.nim` with the following type:

```nim
# file_a.nim
type
    SpecialType* = object
        magical*: string
```

And I have `file_c.nim` that imports `file_a.nim` and uses its type:

```nim
# file_c.nim
import ./file_a.nim
let aVariableThatUsesAType = SpecialType(magical: "always")
```

These files both live in the same folder, and I have both of them open in an IDE, next to each other, editing them and looking at the diagnostics I receive back from the language server.  In the current state, there will be no errors.  

But then, let's say, I change the type in `file_a.nim`, so that `file_c.nim`'s usage of it is incompatible:

```nim
# file_a.nim
type
    SpecialType* = object
        magical*: int
```

The language server should give diagnostics to `file_c.nim` with a little red squiggly line and a hover message informing the user about a type incompatibility.  And it will - as long as `file_c.nim` directly imports `file_a.nim`.  

The problem arises with an intermediate file in the chain. Say we introduce `file_b.nim`:

```nim
# file_b.nim
import ./file_a.nim
export file_a
```

and import it into `file_c.nim`:

```nim
# file_c.nim
import ./file_b.nim
let aVariableThatUsesAType = SpecialType(magical: "always")
```

If `file_b.nim` is closed (not being edited), and I change `file_a.nim` so that `magical` becomes `int`, diagnostics for `file_c.nim` will not be updated - we won't see that red squiggly line.  Why is this?

`nimsuggest` receives three types of relevant messages:
- `changed`
  - Tells `nimsuggest` that a file has been changed i.e. it has unsaved in-memory edits. It hands nimsuggest the stash (dirty file) path so subsequent queries (hover, completion, etc.) compile against the current editor content rather than the on-disk version.  Normally sent on every key-press.  
  - Fast and cheap.
  - e.g. `changed "/abs/path/to/file.nim";"/abs/path/to/dirtyfile.nim":0:0`
- `chkFile`
  - Requests per-file diagnostics for a single file. Nimsuggest compiles only that file (not the full project) and returns any diagnostics.
  - Fast and cheap.
  - e.g. `chkFile "/abs/path/to/foo.nim";"/tmp/storage/abc123.nim":0:0`
- `chk` 
  - Tells `nimsuggest` to recompiles the entire project starting from the entry point and return diagnostics for every file in the project.  Returns errors/warnings across all files, not just the one being edited.
  - Slow and expensive.
  - e.g. `chk "/abs/path/to/foo.nim":0:0`

The problem is that the `chkFile` command does not update transitive dependencies.  In an ideal world, we would just run the `chk` command on every key press and get up-to-date diagnostics for every file in the project constantly, but it is too slow (can be 10+ seconds on a big project) and expensive.  In the example above, `chkFile` will automatically be called on `file_a.nim` and `file_c.nim`, but `file_c.nim` will not get the correct diagnostics because `file_b.nim` would need to have been compiled (`chkFile`) after `file_a.nim`.  This command is not sent because the file is not open, and even if it was we'd have to ensure compilation in dependency order.  How to solve this?  

`Nim Tortoise` solves this by building its own dependency tree using its `forest` library.  It then uses the tree to calculate the relationship between all the files a user has open in their IDE and then call `chkFile` on all dependent files in order (even the ones that are closed): `file_a.nim` -> `file_b.nim` -> `file_c.nim`.  This ensures that the changes get passed up through the chain as each file is individually compiled and has diagnostics for it returned.  This approach is cheap and fast enough that, on the language server's HIGHEST performance setting, you should see diagnostics updating on each key stroke. 

### Status Panel

I have fleshed out the status panel in the VS Code extension, to show a lot of relevant information so that it is easier for a user to track the current state of the Language Server.   It also now provides buttons to stop, recompile or check a particular `nimsuggest` instance, as well as showing all the files it is responsible for, it's current state, the location of the executable etc.   Through it, a user can change the performance mode, see errors and excute tasks in `.nimble` files - most of these are built upon the great work done in the original extension I forked.

## Performance

As someone with an older 2019 macbook who works in cafes where electricity outlets might be at a premium, the performance of the language server (and its effect on my battery life) is very important to me.  This was a main focus of the `Nim Tortoise` rewrite.

### Performance Settings

Unfortunately, `nimsuggest` can be very CPU and RAM hungry.  This is why `Nim Tortoise` has four "performance" settings, so you can choose a balance between immediate diagnostics that will take a toll on your CPU, or a less responsive experience that will give you more battery life.  

These settings are defined by the length of the queue and whether changes are updated on change or save.

- `HIGHEST` setting checks and gives diagnostics back for any open dependencies on any change, meaning that this setting can be quite intensive.  Automatically runs the "check project" command upon saving.
- `HIGH` is similar, but increases the amount of request throttling from a window of 250ms out to 1 second.  
- `LOW` also uses the same 1 second window, but will only update open files which are the dependencies of each other upon the user saving.  The "check project" command is not run automatically, and is only triggered via the VS Code Extension, or by pressing `Ctrl+Alt+S` (in VS Code).
- `LOWEST` works the same as the `LOW` setting, but with a much larger request throttling window of 5 seconds.

### CPU Usage

One of the issues that originally drove me to re-write the `nimlangserver` language server was an issue I was having in which, upon startup, `nimble` would run for 1 minute and 45 seconds at 100% CPU.  This is fixed in `Nim Tortoise` (I also sent this fix as a pull request back to the `nimlangserver` repo).  One of the reasons for this was a problem caused by the correct `PATH` information not being passed to `nimble` when the VS Code extension spawned it.  In `Nim Tortoise`, `nim`, `nimsuggest` and `nimble` are all spawned from the server, rather than the extension, with care taken that the types of errors that can occur (especially on MacOS, in which VS Code inherits a minimal `PATH` via the Dock) are reduced.

### Queuing Requests

`Nim Tortoise` has a queuing system for each `nimsuggest` instance that holds all queries for `nimsuggest`.  Due to the high CPU-usage of `nimsuggest`, this queue is used to thin out the number of requests that `nimsuggest` actually has to run, using a set of criteria that should not diminish the user experience...

### Message Throttling

When a `changed` query is added to the queue of a `nimsuggest` instance, `Nim Tortoise` checks when the last processed `changed` query was for that file and if it has occured within a time period defined by the `Request throttling` parameter, the queue is artificially paused, until that amount of time has passed.  While the queue is paused new queries are added to the queue and stack up behind the paused `changed` function.  Given that the changed function of a file is generated on every key press or change to a file, this pausing of the queue prevents `nimsuggest` having to process every single `changed` message (thus cutting down on its CPU footprint).  When a user is rapidly typing, or making a lot of changes to a file in quick succession, `nimsuggest` does not need to process all of these queries, only the very last in the burst of changes.  Upon popping each `changed` command off the front of the queue, `Nim Tortoise` checks if there is a more recent `changed` request for the file, and cancels the request if this is true - saving `nimsuggest` from having to process it.  

Additionally, queries such as `hover`, `highlight`, and `outline` that fire frequently but are dependent upon the current state of a file, are removed from the queue if there is a later `changed` request for the same file already in the queue.

### Duplicate request removal

`Nim Tortoise`'s queueing system also allows for the removal of requests which fire frequently but which are unnecessary.  For instance, an IDE may send multiple `hover` requests for the same position in a document, due to the user moving their mouse a very small amount - this would create duplicate work for `nimsuggest`, so duplicate requests within the queue are cancelled.

### Response Caching

The `outline` request is frequently sent by VS Code, but contains a relatively low rate-of-change.  Caches are set up for hover requests, document highlight request and document symbols requests, to further reduce the amount of requests `nimsuggest` has to process, further reducing CPU usage.


### RAM Usage

`nimsuggest` uses a lot of RAM, fundamentally because it loads a representation of the entire code it is analysing into memory.  Because of this, it is important that any language server properly enforces the maximum amount of `nimsuggest` instances that it runs, and also tries to ensure no more instances than are necessary are running.

One of the problems `nimlangserver` has, and has been reported over a number of different forums, threads etc. is that it often did not respect the maximum number of instances running - sometimes this was due to hanging processes that were not quit properly, but often it was due to some code paths missing the correct guards (I also made a pull request to `nimlangserver` correcting this problem).  `Nim Tortoise` tries to ensure that, when you set a maximum number of `nimsuggest` instances, this is always abided by.  `Nim Tortoise` has a "pool" of "slots", each of which holds a `nimsuggest` instance.  This pool is responsible for two important mechanisms that help reduce RAM usage:

1. Eviction
2. Consolidation

### Eviction

`Nim Tortoise` employs an "eviction" mechanism to close `nimsuggest` instances when the "pool" has reached its maximum number of instances.  It chooses which slot(s) should be shutdown and removed using this order of prioritisation:

1. Slots whose state is STOPPED or STOPPING
  - if more than one, keep the slot with the file that was saved most recently.
2. Slots whose state is CRASHED
  - if more than one, keep the slot with the file that was saved most recently.
3. Slots who serve no files
4. Slots whose files were saved that longest time ago.

These criteria prioritise working slots, followed by those whose files the user has worked on most recently.

### Consolidation

The second mechanism is "consolidation" of slots.  Because `nimsuggest` loads a representation of the entire code base into memory, starting from the entry point file it is directed at, there can be situations in which a user is in the following situation (one compounded by `nimlangserver`'s use of `projectMapping` regex's as a way to define entry points).

If you are a user using `nimlangserver` with a settings.json as follows:

```
{
    "nim.projectMapping": [{
        "projectFile": "tests/all.nim",
        "fileRegex": "tests/.*\\.nim"
    }, {
        "projectFile": src/main.nim",
        "fileRegex": "src/.*\\.nim"
    }]
}
```

When you open a file in the `src` folder of a module, `nimlangserver` would spawn a `nimsuggest` instance with an entry point of `src/main.nim`.  During this, `nimsuggest` would load the entirety of this module into memory.  

If you then opened a file in the `tests/` folder (and your maximum nimsuggest instances are more than 1), `nimlangserver` would spawn a new instance with an entry point of `tests/all.nim`.  However, the tests for a module most likely import the contents of the `src` folder in order to test them, meaning that when `nimsuggest` spawns for `tests/all.nim` it is probably loading the entirety of the `src` files as well, as these are dependencies of the tests, and `nimsuggest` loads all dependencies into memory.  You now have two instances of `nimsuggest` containing the same `src` file information when, in essence, both the `test` and `src` files could be served from the single `test/all.nim` instance.  

To prevent this, `Nim Tortoise` implements a consolidation process that checks for these types of relationships and will consolidate `nimsuggest` instances that serve the same files, and closing any uneccesary ones, so that the least amount of `nimsuggest` instances are running, saving RAM.  In this case, the `src/main.nim` instance would be closed, and all served files for the `src/*.nim` folder would be migrated over to the `test/all.nim` instance.

## Others

Those are the big changes, but there are a set of other smaller improvements in `Nim Tortoise`:

- improved syntax highlighting
- improved autocomplete (e.g. for `##[]##`)
- Improved highlighting for compiler-internal symbol names e.g.  `:anonymous`, `:result`, `:tmp`, `:env`, `:iterator`, `:objectType`
- More readable proc error messages
- Warning message for when nimsuggest erroneously reports that two identical types are not the same.
- A website for benchmarking the debug output.

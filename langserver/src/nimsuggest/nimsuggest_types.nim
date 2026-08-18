import std/[json, sets, tables, times]
import chronos
import regex
import ./suggestapi_types
import ../protocol/types
import ../utils/utils as globalUtils
export FileUri, FilePathAbs, FilePathRel, DirPathAbs, DirPathRel

# === NIMSUGGEST QUERIES ===
# LSP File Position
type
  Line0Based* = distinct int # 0-based (VS Code/LSP convention)
  Utf16Int* = distinct int # UTF-16 byte column (VS Code/LSP convention)
  
  LspFilePosition* = object
    line*: Line0Based # 0-based (VS Code/LSP convention)
    character*: Utf16Int  # UTF-16 byte column (VS Code/LSP convention)

# Nimsuggest File Position
  NimsuggestFilePosition* = object
    line*: int  ## 1-based (nimsuggest convention)
    col*: int   ## UTF-8 byte column

type
  NimsuggestQueryKind* {.pure.} = enum
    SUGGEST           ## sug          — completion items at position
    DEFINITION        ## def          — go-to-definition
    DECLARATION       ## declaration  — go-to-declaration
    TYPE_DEFINITION   ## type         — go-to-type-definition
    REFERENCES        ## use          — find all references
    DOCUMENT_SYMBOLS  ## outline      — file symbol tree
    WORKSPACE_SYMBOLS ## globalSymbols — workspace-wide symbol search
    HOVER              ## highlight — symbol info at position
    DOCUMENT_HIGHLIGHT ## highlight — all occurrences in file
    SIGNATURE_HELP     ## con        — overload list at call site
    INLAY_HINTS        ## inlayHints — type / parameter / exception hints
    EXPAND             ## expand — macro expansion at position
    CHANGED            ## changed — notify nimsuggest of unsaved edits (stash)
    CHECK_FILE         ## chkFile — per-file diagnostics
    CHECK_PROJECT      ## chk     — full project diagnostics
    RECOMPILE          ## recompile — force full in-process recompile
    KNOWN              ## known     — is this file in the module graph?
    SHUTDOWN           ## sentinel  — drains remaining queries, shuts down process, exits loop

  NimsuggestQuery*[P] = ref object
    id*: uint
    uri*: FileUri
      ## Source URI. Used to resolve the on-disk path and stash path.
    dirtyFile*: FilePathAbs
      ## Stash path when openFiles[uri].changed is true, else "".
    responseFuture*: Future[seq[Suggest]]
      ## Completed by the query processor when nimsuggest replies.
    cancelled*: bool
      ## Set by $/cancelRequest. processQueries completes responseFuture
      ## with @[] immediately if true. Safe across coroutines (ref + single-threaded).
    case kind*: NimsuggestQueryKind
    of NimsuggestQueryKind.SUGGEST,
      NimsuggestQueryKind.DEFINITION,
      NimsuggestQueryKind.DECLARATION,
      NimsuggestQueryKind.TYPE_DEFINITION,
      NimsuggestQueryKind.REFERENCES,
      NimsuggestQueryKind.HOVER,
      NimsuggestQueryKind.DOCUMENT_HIGHLIGHT,
      NimsuggestQueryKind.SIGNATURE_HELP:
      position*: P
    of NimsuggestQueryKind.INLAY_HINTS:
      inlayHints*: tuple[start, finish: P, options: string]
    of NimsuggestQueryKind.EXPAND:
      expand*: tuple[position: P, tag: string]
    of NimsuggestQueryKind.DOCUMENT_SYMBOLS,
      NimsuggestQueryKind.WORKSPACE_SYMBOLS,
      NimsuggestQueryKind.CHECK_FILE,
      NimsuggestQueryKind.CHECK_PROJECT,
      NimsuggestQueryKind.RECOMPILE,
      NimsuggestQueryKind.KNOWN:
      discard
    of NimsuggestQueryKind.SHUTDOWN:
      shutdownFuture*: Future[void]
        ## Completed by processNimsuggestQueries after shutdownChildProcess returns.
        ## execStop awaits this to know the OS process is confirmed dead.
    of NimsuggestQueryKind.CHANGED:
      saved*: bool

# === NIMSUGGEST SLOT TYPES ====
type
  SlotState* {.pure.} = enum
    STOPPED   ## No process. After stop, before re-spawn or removal.
    SPAWNING  ## Spawn in progress; ns future is pending.
    READY     ## Process live; queries accepted.
    STOPPING  ## STOP running; queries return @[].
    CRASHED   ## Process exited unexpectedly; RESTART queued by processor.

##[
Realize that there are three types of file:
- the entry point file
- the working directory nimsuggest is running from
- The base nimble project.

e.g.
in `langserver`:
if I have opened a file in the `tests` folder:
- file I'm working on: langserver/tests/textensions.nim
- entry point: langserver/tests/all.nim
- workingDirectory: langserver/tests
- base nimble project folder: langserver (langserver/nimtortoise.nimble)
]##

type
  NimsuggestSlot* = ref object
    state*: SlotState
    # entryFile*: FilePath # Entry-point .nim path. 
    spawnInfo*: NimsuggestSpawnInfo
    # projectFile*: FilePathAbs # Entry-point .nim path. Stable across restarts. Key in pool.slots.
    # workingDir*: DirPathAbs   # Working directory passed to nimsuggest at spawn time. Stable across restarts.
    # nimblePaths*: seq[string]
      ## A list of flags from any relevant nimble.paths files.   These are passed to nimsuggest when it runs.  I wonder if these should be part of the nimbleDumpCache?
      ## isEntryPoint*: bool
      ## Discovered via nimble dump during `initialized`.
    ownedUris*: HashSet[FileUri]
      ## The single source of truth for which URIs this slot serves.
    crashedUris*: HashSet[FileUri]
      ## URIs that caused a SIGSEGV in this slot's process.
    ns*: Future[NimSuggest]
      ## pending = SPAWNING, completed = READY, failed = CRASHED.
      ## SlotState is the sole lifecycle authority; ns is the async handle.
    queryMailbox*: AsyncQueue[NimsuggestQuery[LspFilePosition]]
      ## IDE query commands. processQueries dequeues and dispatches to TCP.
    lastCmdTime*: DateTime
      ## Updated after each successful query. Drives LRU eviction policy.
    crashCount*: int
      ## Incremented on unhandled exit. Reset to 0 on successful init.

type
  ProjectMapping* = object
    projectFile*: FilePathAbs
    fileRegex: Regex2

# === NIMSUGGEST POOL TYPES ===
type
  NotifyProc* = proc(meth: string, params: JsonNode) {.gcsafe, raises: [].}
  StatusChangedProc* = proc() {.gcsafe, raises: [].}

  NimsuggestPool* = ref object
    slots*: Table[FilePathAbs, NimsuggestSlot]
    maxSlots*: int
    nimsuggest*: NimsuggestSettings
    notifyProc*: NotifyProc
      ## Sends a JSON-RPC notification to the client (e.g. window/showMessage).
      ## Set by initLanguageServer. May be nil — check before calling.
    statusChangedProc*: StatusChangedProc
      ## Called when a slot transitions to READY or is removed.
      ## Triggers extension/statusUpdate. Set by initLanguageServer. May be nil.
      ## 
    
    
    # nimVersion*: string      ## Nim version string for logging.
    # timeout*: int            ## Per-request timeout in ms.
    # projectMapping*: seq[ProjectMapping]
    # nimsuggestPath*: FilePathAbs  ## Path to nimsuggest binary. Set in initNimsuggestInstances.
    # nimsuggestProtocol*: int
    # nimsuggestCapabilities*: set[NimSuggestCapability]


type
  NlsFileInfo* = ref object of RootObj
    slot*: NimsuggestSlot
      ## The pool slot responsible for this file. Assigned in addFileToOpenFiles.
      ## Always non-nil for any file present in ls.files.openFiles.
    # changed*: bool
    fingerTable*: seq[seq[tuple[u16pos, offset: int]]]
    lastChanged*: DateTime
      ## Updated on every DID_CHANGE.
    lastChecked*: DateTime
      ## Set to now() when a chkFile or checkProject completes for this URI.
      ## Prevents duplicate checks within FILE_CHECK_DELAY of each other.
    textDocument*: TextDocumentItem

type
  LanguageServerFiles* = object
    openFiles*:   TableRef[FileUri, NlsFileInfo]
    storageDir*:  DirPathAbs
    rootPath*:    DirPathAbs

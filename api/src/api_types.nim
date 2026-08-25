import std/[json, options]
import forest

type
  ExecuteCommandRequestParams* = ref object of RootObj
    command*: string
    arguments*: JsonNode

type
  LspExtensionCapability* = enum
    # List of extensions this server support. Useful for clients
    SERVER_STATUS             = "ServerStatus",
    SERVER_CAPABILITIES       = "ServerCapabilities",
    SERVER_RESTART            = "ServerRestart",
    NIMSUGGEST_RESTART_ALL    = "NimsuggestRestartAll",
    NIMSUGGEST_RESTART        = "NimsuggestRestart",
    NIMSUGGEST_RECOMPILE      = "NimsuggestRecompile",
    NIMSUGGEST_CHECK_PROJECT  = "NimsuggestCheckProject",
    NIMSUGGEST_STOP           = "NimsuggestStop",
    NIMBLE_LIST_TASKS         = "NimbleListTasks",
    NIMBLE_RUN_TASK           = "NimbleRunTask",
    NIM_MACRO_EXPAND          = "NimMacro"

type
  NimSuggestCapability* = enum
    nsCon = "con"
    nsExceptionInlayHints = "exceptionInlayHints"
    nsUnknownFile = "unknownFile"

  NimSuggestStatus* = object
    projectFile*: string
    capabilities*: seq[NimSuggestCapability]
    protocol*: string
    version*: string
    path*: string
    port*: int
    openFiles*: seq[string]
    unknownFiles*: seq[string]

  PendingRequestStatus* = object
    name*: string
    projectFile*: string
    time*: string
    state*: string

  ProjectError* = object
    projectFile*: string
    errorMessage*: string
    lastKnownCmd*: string

  NimLangServerStatus* = object
    lspPath*: string
    version*: string
    nimsuggestInstances*: seq[NimSuggestStatus]
    openFiles*: seq[string]
    extensionCapabilities*: seq[LspExtensionCapability]
    pendingRequests*: seq[PendingRequestStatus]
    projectErrors*: seq[ProjectError]

  NimLangServerStatusParams* = object of RootObj

type
  NimbleRunTaskRequest* = object
    command*: seq[string] # command and args
    workingDir*: DirPathAbs # directory in which to run the 

  NimbleRunTaskResponse* = object
    command*: seq[string] # command and args
    output*: seq[string] # output lines

  NimbleTask* = object
    name*: string
    description*: string
    projectDir*: DirPathAbs ## absolute directory where nimble was run

type 
  ExtensionCommandRequest* = object
    case kind*: LspExtensionCapability
    of 
      SERVER_STATUS, 
      SERVER_CAPABILITIES, 
      SERVER_RESTART: 
      discard      
    of NIMSUGGEST_RESTART_ALL: discard
    of 
      NIMSUGGEST_RESTART,
      NIMSUGGEST_RECOMPILE, 
      NIMSUGGEST_CHECK_PROJECT, 
      NIMSUGGEST_STOP:
      slot*: FilePathAbs
    of NIMBLE_LIST_TASKS: discard
    of NIMBLE_RUN_TASK: 
      nimbleRunTask*: NimbleRunTaskRequest
    of NIM_MACRO_EXPAND: discard

  ExtensionCommandResponse* = object
    case kind*: LspExtensionCapability
    of SERVER_STATUS:
      serverStatus*: NimLangServerStatus
    of SERVER_CAPABILITIES:
      serverCapabilities*: seq[LspExtensionCapability]
    of SERVER_RESTART: discard      

    of 
      NIMSUGGEST_RESTART_ALL,
      NIMSUGGEST_RESTART,
      NIMSUGGEST_RECOMPILE, 
      NIMSUGGEST_CHECK_PROJECT, 
      NIMSUGGEST_STOP:
      discard

    of NIMBLE_LIST_TASKS: 
      nimbleListTasks*: seq[NimbleTask]
    of NIMBLE_RUN_TASK: 
      nimbleRunTask*: NimbleRunTaskResponse
    of NIM_MACRO_EXPAND: discard

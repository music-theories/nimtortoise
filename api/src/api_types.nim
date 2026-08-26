import std/[json, times]
import resources/resources

type
  MessageType* {.pure.} = enum
    Error = 1
    Warning = 2
    Info = 3
    Log = 4
    Debug = 5

type
  ExecuteCommandRequestParams* = ref object of RootObj
    command*: string
    arguments*: JsonNode

type
  LspExtensionCapability* = enum
    # List of extensions this server support. Useful for clients
    SERVER_STATUS             = "serverStatus",
    SERVER_CAPABILITIES       = "serverCapabilities",
    SERVER_RESTART            = "serverRestart",
    NIMSUGGEST_RESTART        = "nimsuggestRestart",
    NIMSUGGEST_RECOMPILE      = "nimsuggestRecompile",
    NIMSUGGEST_CHECK_PROJECT  = "nimsuggestCheckProject",
    NIMSUGGEST_STOP           = "nimsuggestStop",
    NIMBLE_LIST_TASKS         = "nimbleListTasks",
    NIMBLE_RUN_TASK           = "nimbleRunTask",
    NIM_MACRO_EXPAND          = "nimMacro"

type
  NimTortoiseExeStatus* = object
    path*: FilePathAbs
    version*: string

type
  PerformanceSettingKind* {.pure.} = enum
    HIGHEST = "HIGHEST",
    HIGH = "HIGH",
    LOW = "LOW",
    LOWEST = "LOWEST"

  PerformanceSetting* = object
    kind*: PerformanceSettingKind
    fileCheckThrottling*: times.Duration
    updateOnChange*: bool
    description*: string

  PerformanceSettingJs* = object
    kind*: PerformanceSettingKind
    updateOnChange*: bool
    when defined(js):
      fileCheckThrottling*: cstring
    else:
      fileCheckThrottling*: string

type
  PendingRequestStatus* = object
    name*: string
    entryPoint*: FilePathAbs
    time*: string
    state*: string

  ProjectError* = object
    entryPoint*: FilePathAbs
    errorMessage*: string
    lastKnownCmd*: string

type
  NimsuggestCapability* = enum
    nsCon = "con"
    nsExceptionInlayHints = "exceptionInlayHints"
    nsUnknownFile = "unknownFile"

type
  NimsuggestStatus* = object
    state*: string 
    entryPoint*: FilePathAbs
    protocol*: string
    version*: string
    path*: string
    port*: int
    openFiles*: seq[string]

type
  NimTortoiseServerStatus* = object
    extensionCapabilities*: seq[LspExtensionCapability]
    performance*: PerformanceSettingJs
    exe*: NimTortoiseExeStatus
    openFiles*: seq[FilePathAbs]
    pendingRequests*: seq[PendingRequestStatus]
    projectErrors*: seq[ProjectError]
    pool*: seq[NimsuggestStatus]

  NimTortoiseServerStatusParams* = object of RootObj

type
  NimbleRunTaskRequest* = object
    when defined(js):
      command*: seq[cstring]
      workingDir*: cstring
    else:
      command*: seq[string] # command and args
      workingDir*: DirPathAbs # directory in which to run the

  NimbleRunTaskResponse* = object
    when defined(js):
      command*: seq[cstring]
      output*: seq[cstring]
    else:
      command*: seq[string] # command and args
      output*: seq[string] # output lines

  NimbleTask* = object
    when defined(js):
      name*: cstring
      description*: cstring
      projectDir*: cstring
    else:
      name*: string
      description*: string
      projectDir*: DirPathAbs ## absolute directory where nimble was run
    isRunning*: bool ## client-side state; never set by the server

type 
  ExtensionCommandRequest* = object
    case kind*: LspExtensionCapability
    of 
      SERVER_STATUS, 
      SERVER_CAPABILITIES, 
      SERVER_RESTART: 
      discard
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
      serverStatus*: NimTortoiseServerStatus
    of SERVER_CAPABILITIES:
      serverCapabilities*: seq[LspExtensionCapability]
    of SERVER_RESTART: discard      

    of 
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

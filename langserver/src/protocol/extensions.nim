import ./primitives
export primitives

# TODO
# type
#   LspExtensionCapability* = enum
#     # List of extensions this server support. Useful for clients
#     SERVER_RESTART = "ServerRestart",
#     NIMSUGGEST_RESTART = "NimsuggestRestart",
#     NIMSUGGEST_CHECK_PROJECT = "NimsuggestCheckProject",
#     NIMSUGGEST_RECOMPILE = "NimsuggestRecompile",
#     NIMBLE_LIST_TASKS = "NimbleListTasks",
#     NIMBLE_RUN_TASK = "NimbleRunTask",
#     NIM_MACRO_EXPAND = "NimMacro"

type
  LspExtensionCapability* = enum
    #List of extensions this server support. Useful for clients
    excRestartSuggest = "RestartSuggest"
    excNimbleTask = "NimbleTask"
    excRunTests = "RunTests"

type
  NimSuggestCapability* = enum
    nsCon = "con"
    nsExceptionInlayHints = "exceptionInlayHints"
    nsUnknownFile = "unknownFile"

  NimSuggestStatus* = object
    projectFile*: string
    capabilities*: seq[NimSuggestCapability]
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

type
  NimLangServerStatusParams* = object

  SuggestAction* = enum
    saNone = "none"
    saRestart = "restart"
    saRestartAll = "restartAll"

  SuggestParams* = object
    action*: SuggestAction
    projectFile*: string #Absolute path to file

  SuggestResult* = object
    actionPerformed*: SuggestAction

  NimbleTask* = object
    name*: string
    description*: string
    projectDir*: string ## absolute directory where nimble was run

  RunTaskParams* = object
    command*: seq[string] #command and args
    workingDir*: string ## directory in which to run the task

  RunTaskResult* = object
    command*: seq[string] #command and args
    output*: seq[string] #output lines

  # TestInfo* = object
  #   name*: string
  #   line*: int
  #   file*: string

  # TestSuiteInfo* = object
  #   name*: string #The suite name, empty if it's a global test
  #   tests*: seq[TestInfo]

  # TestProjectInfo* = object
  #   entryPoint*: string
  #   suites*: Table[string, TestSuiteInfo]
  #   error*: string ## empty string means no error

  # ListTestsParams* = object
  #   entryPoint*: string
      #can be patterns? if empty we could do the same as nimble does or just run `nimble test args`

  # ListTestsResult* = object
  #   projectInfo*: TestProjectInfo

  # RunTestResult* = object
  #   name*: string
  #   time*: float
  #   failure*: string ## empty string means the test passed

  # RunTestSuiteResult* = object
  #   name*: string
  #   tests*: int
  #   failures*: int
  #   errors*: int
  #   skipped*: int
  #   time*: float
  #   testResults*: seq[RunTestResult]

  # RunTestParams* = object
  #   entryPoint*: string
  #   suiteName*: string ## empty string means no suite filter
  #   testNames*: seq[string] ## empty seq means no test filter

  # RunTestProjectResult* = object
  #   suites*: seq[RunTestSuiteResult]
  #   fullOutput*: string

  # CancelTestResult* = object
  #   cancelled*: bool

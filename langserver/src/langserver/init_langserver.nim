import std/[macros, options, tables, setutils, json, times, os]

import chronos
import json_serialization
import json_rpc/[servers/socketserver]
import chronicles

import forest

import ../nimble/nimble_types
import ../protocol/[enums, types]
import ../configurations/configurations
import ../nimsuggest/nimsuggest
import ../utils/utils
import ../utils/asyncprocmonitor

import ./[
  query_types, langserver_messaging, 
  capability_configs, langserver_nimsuggest,
  langserver_utils, langserver_types
]

proc initLanguageServer*(params: CommandLineParams, storageDir: FilePath): LanguageServer =
  let currentConfig = initDefaultNlsConfig()
  let configReady = newAsyncEvent()
  result = LanguageServer(
    capabilities: LanguageServerCapabilities(
      extensionCapabilities: LspExtensionCapability.items.toSet,
    ),
    configurations: LanguageServerConfigurations(
      currentConfig: initDefaultNlsConfig(),
      configReady: configReady,
    ),
    transport: LanguageServerTransport(
      transportMode: params.transport.get(TransportMode.stdio),
    ),
    files: LanguageServerFiles(
      openFiles: newTable[FileUri, NlsFileInfo](),
      # idleOpenFiles: newTable[FileUri, NlsFileInfo](),
      storageDir: storageDir,
    ),
    messaging: LanguageServerMessaging(
      pendingRequests: initTable[uint, PendingRequest](),
      responseMap: newTable[string, Future[JsonNode]](),
      responseNames: newTable[string, string](),
      projectErrors: @[],
    ),
    nimbleDumpCache: initTable[FilePath, NimbleDumpInfo](),
    cmdLineClientProcessId: params.clientProcessId,
    lspQueue: newAsyncQueue[LspDispatchItem](),
    langserverQueue: newAsyncQueue[LangserverQuery](),
    lsInitialized: newFuture[void]("lsInitialized"),
  )
  # Create the pool synchronously so ls.pool is never nil when event loop starts.
  # initNimsuggestInstances will update maxSlots from config and spawn entry points.
  let ls = result
  result.pool = NimsuggestPool(
    slots: initTable[FilePath, NimsuggestSlot](), 
    maxSlots: currentConfig.maxNimsuggestProcesses, 
    fileCheckDelay: initDuration(milliseconds = currentConfig.fileCheckDelay),
    # timeout: currentConfig.langserverTimeout,
    nimsuggestPath: toFilePath(currentConfig.nimsuggestPath),
    nimVersion: "", # Set in initNimsuggestInstances
    notifyProc: proc(meth: string, params: JsonNode) {.gcsafe, raises: [].} =
    ls.notify(meth, params),
    statusChangedProc: proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      ls.sendStatusChanged()
  )

proc tick*(ls: LanguageServer): Future[void] {.async.} =
  try:
    ls.removeCompletedPendingRequests()
    ls.sendStatusChanged()
  except CatchableError as ex:
    error "Error in tick", msg = ex.msg
    writeStacktrace(ex)


# initialize = capability exchange
# initialized = startup work begins

proc getNphPath*(): Option[string] =
  let path = findExe "nph"
  if path == "":
    none(string)
  else:
    some path

# === initialize ===
proc initialize*(
  p: tuple[ls: LanguageServer, onExit: OnExitCallback], 
  params: LspInitializeParams
): Future[LspInitializeResult] {.async.} =
  # initialize — a request (client waits for a response). The client sends its capabilities and the server responds with its own capabilities. This stores lspInitializeParams, sets up the client process monitor, and returns LspServerCapabilities. Nimsuggest is not started here.
  proc onClientProcessExitAsync(): Future[void] {.async.} =
    debug "onClientProcessExitAsync"
    await p.ls.pool.stopNimsuggestProcesses()
    await p.onExit()

  proc onClientProcessExit() {.closure, gcsafe.} =
    try:
      debug "onClientProcessExit"
      waitFor onClientProcessExitAsync()
    except Exception:
      error "Error in onClientProcessExit ", msg = getCurrentExceptionMsg()

  debug "Initialize received..."
  if params.processId.isSome:
    let pid = params.processId.get
    if pid.kind == JInt:
      debug "Registering monitor for process ", pid = pid.num
      var pidInt = int(pid.num)
      if p.ls.cmdLineClientProcessId.isSome:
        if p.ls.cmdLineClientProcessId.get == pidInt:
          debug "Process ID already specified in command line, no need to register monitor again"
        else:
          debug "Warning! Client Process ID in initialize request differs from the one, specified in the command line. This means the client violates the LSP spec!"
          debug "Will monitor both process IDs..."
          hookAsyncProcMonitor(pidInt, onClientProcessExit)
      else:
        hookAsyncProcMonitor(pidInt, onClientProcessExit)
  p.ls.capabilities.lspInitializeParams = params
  p.ls.capabilities.lspClientCapabilities = params.capabilities
  result = LspInitializeResult(
    capabilities: LspServerCapabilities(
      textDocumentSync: some(
        %TextDocumentSyncOptions(
          openClose: some(true),
          change: some(TextDocumentSyncKind.Full.int),
          willSave: some(false),
          willSaveWaitUntil: some(true),
          save: some(SaveOptions(includeText: some(true))),
        )
      ),
      hoverProvider: some(true),
      workspace: some(
        ServerCapabilities_workspace(
          workspaceFolders: some(WorkspaceFoldersServerCapabilities()),
          fileOperations: some(
            ServerCapabilities_workspace_fileOperations(
              didRename: some(
                FileOperationRegistrationOptions(
                  filters: @[
                    FileOperationFilter(
                      scheme: some("file"),
                      pattern: FileOperationPattern(glob: "**/*.nim"),
                    )
                  ]
                )
              ),
              didDelete: some(
                FileOperationRegistrationOptions(
                  filters: @[
                    FileOperationFilter(
                      scheme: some("file"),
                      pattern: FileOperationPattern(glob: "**/*.nim"),
                    )
                  ]
                )
              ),
            )
          ),
        )
      ),
      completionProvider:
        CompletionOptions(triggerCharacters: some(@["."]), resolveProvider: some(false)),
      signatureHelpProvider: SignatureHelpOptions(triggerCharacters: some(@["(", ","])),
      definitionProvider: some(true),
      declarationProvider: some(true),
      typeDefinitionProvider: some(true),
      referencesProvider: some(true),
      documentHighlightProvider: some(true),
      workspaceSymbolProvider: some(true),
      executeCommandProvider: some(
        ExecuteCommandOptions(
          commands: some(@[
            "nimtortoise.recompile",
            "nimtortoise.restart",
            "nimtortoise.checkProject"
          ])
        )
      ),
      inlayHintProvider: some(InlayHintOptions(resolveProvider: some(false))),
      documentSymbolProvider: some(true),
      codeActionProvider: some(true),
      documentFormattingProvider: some(getNphPath().isSome),
    )
  )
  # Support rename by default, but check if we can also support prepare
  result.capabilities.renameProvider = %true
  if params.capabilities.textDocument.isSome:
    let docCaps = params.capabilities.textDocument.unsafeGet()
    # Check if the client support prepareRename
    #TODO do the test on the action
    if docCaps.rename.isSome and docCaps.rename.get().prepareSupport.get(false):
      result.capabilities.renameProvider = %*{"prepareProvider": true}

  debug "Initialize completed. Nimsuggest instances will start after configuration arrives."

  let ls = p.ls
  ls.capabilities.lspServerCapabilities = result.capabilities

# === initialized ===
proc initialized*(ls: LanguageServer, _: JsonNode): Future[void] {.async.} =
  # initialized — a notification (no response). Sent by the client after it has processed the initialize response and is ready to proceed. This is where real work happens: config is fetched, configReady fires, initNimsuggestInstances runs, and lsInitialized is completed.
  debug "Client initialized."
  ls.maybeRegisterCapabilityDidChangeConfiguration()

  if ls.supportsConfigurationRequest:
    debug "Requesting configuration from the client"
    
    let configurationParams = %*{"items": [{"section": "nimTortoise"}, {"section": "nim"}]}
    
    let configFuture = ls.call("workspace/configuration", configurationParams)

    try:
      let conf = await configFuture
      debug "Received the following configuration", configuration = conf
      let newConfiguration: Option[NlsConfig] = parseWorkspaceConfigurationResponse(conf)
      if newConfiguration.isSome: 
        let newConfigValue = newConfiguration.get()
        let newConfigurationIsDifferent = isDifferentFrom(newConfigValue, ls.configurations.currentConfig)

        if newConfigurationIsDifferent:
          ls.configurations.currentConfig = newConfigValue

      ls.configurations.configReady.fire()
    except CatchableError as ex:
      debug "Failed to receive workspace configuration", error = ex.msg

  else:
    debug "Client does not support workspace/configuration"
    ls.configurations.configReady.fire()

  # await ls.initNimsuggestInstances()

  ## Starts nimsuggest instances.
  # let rootPath = getRootPath(ls.capabilities.lspInitializeParams)

  let paramsRootPath: Option[FileUri] = ls.capabilities.lspInitializeParams.rootUri

  if paramsRootPath.isNone():
    debug "initialized: no rootPath found.  Quitting."
    return 
  
  else:
    let rootUri: FileUri = paramsRootPath.get()
    if string(rootUri).len > 0:
      let path = uriToPath(rootUri)
      debug "getRootPath: rootUri on LSPInitializeParams found ", path = path
      ls.files.rootPath = path
    else:
      debug "getRootPath: rootUri on LSPInitializeParams is none()."
      return

  let config = ls.configurations.currentConfig

  # Update pool settings from config (pool was created with defaults in initLanguageServer)
  ls.pool.maxSlots = config.maxNimsuggestProcesses
  ls.pool.fileCheckDelay = initDuration(milliseconds = config.fileCheckDelay)

  # Get all nimble information
  let dependencyTree = initForest(ls.files.rootPath)


  let foundNimbleFiles: seq[FilePath] = searchForNimbleFiles(ls.files.rootPath)
  var nimsuggestSet = false

  for i, nimbleFile in foundNimbleFiles:
    let nimbleDumpInfo: NimbleDumpInfo = await getNimbleDumpInfo(ls.nimbleDumpCache, nimbleFile)

    if not(nimbleFile in ls.nimbleDumpCache):
      ls.nimbleDumpCache[nimbleFile] = nimbleDumpInfo

    if nimsuggestSet == false:
      # Resolve the nimsuggest binary path and Nim version now that config is available.
      let (nimsuggestPath, nimVersion) = await getNimSuggestPathAndVersion(nimbleDumpInfo, config)
      ls.pool.nimVersion = nimVersion
      let nsPath = toFilePath(nimsuggestPath)

      ls.pool.nimsuggestPath = nsPath
      ls.pool.nimsuggestProtocol = detectNimsuggestProtocolVersion(nsPath)
      ls.pool.nimsuggestCapabilities = getNimsuggestCapabilities(nsPath)

      nimsuggestSet = true

  if not ls.lsInitialized.finished:
    ls.lsInitialized.complete()

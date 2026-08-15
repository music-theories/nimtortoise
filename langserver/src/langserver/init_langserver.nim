import std/[macros, options, tables, setutils, json, times]

import chronos
import json_serialization
import json_rpc/[servers/socketserver]
import chronicles

import ../nimble/nimble_types
import ../protocol/[enums, types]
import ../configurations/configurations
import ../nimsuggest/nimsuggest
import ../utils/utils

import ./[langserver_types, query_types, langserver_messaging]

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
    nimsuggestPath: currentConfig.nimsuggestPath, # Set in initNimsuggestInstances
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

import std/[json, options, times, tables]
import chronos
import chronicles
import forest
import ./[configuration_types]

func inlayHintsEnabled*(cnf: NlsConfig): bool =
  return cnf.inlayHints.typeHints.enable or cnf.inlayHints.exceptionHints.enable or cnf.inlayHints.parameterHints.enable

proc initPerformanceSettings*(): Table[PerformanceSettingKind, PerformanceSetting] = 
  result = initTable[PerformanceSettingKind, PerformanceSetting]()

  result[PerformanceSettingKind.HIGHEST] =  PerformanceSetting(
    fileCheckThrottling: initDuration(milliseconds = 200),
    updateOnChange: true,
    description: "Update open dependencies on change. Low request throttling. Highest CPU usage."
  )
  result[PerformanceSettingKind.HIGH] = PerformanceSetting(
    fileCheckThrottling: initDuration(seconds = 1),
    updateOnChange: true,
    description: "Update open dependencies on change. Medium request throttling. High CPU usage."
  )
  result[PerformanceSettingKind.LOW] = PerformanceSetting(
    fileCheckThrottling: initDuration(seconds = 1),
    updateOnChange: false,
    description: "Only update dependencies on save.  Medium request throttling. Low CPU usage."
  )
  result[PerformanceSettingKind.LOWEST] = PerformanceSetting(
    fileCheckThrottling: initDuration(seconds = 5),
    updateOnChange: false,
    description: "Only update dependencies on save.  High request throttling. owest CPU usage."
  )

const performanceSettings = initPerformanceSettings()

proc initDefaultNlsConfig*(): NlsConfig = 
  return NlsConfig(
    # --- Files/Folders ---
    # projectMapping: @[],
    # workingDirectoryMapping: @[],
    # --- Save Settings ---
    # checkOnSave: true,
    # checkDependentsOnChange: true,
    # formatOnSave: false,
    # --- Langserver settings --- 
    # langserverTimeout: 1_800_000, # in MS - This is 30 mins
    # fileCheckDelay: initDuration(milliseconds = 1000), # in MS
    performance: performanceSettings[PerformanceSettingKind.LOW],
    # -- Nimsuggest Settings ---
    maxNimsuggestProcesses: 2, # max number of nimsuggest processes to keep alive. 0 means unlimited.
    maxNimsuggestCrashRetries: 3, # auto-restart attempts before giving up on a crashed slot
    nimsuggestPath: FilePathAbs(""), # OR should it be "nimsuggest"?
    nimsuggestIdleTimeout: initDuration(seconds = 1800), 
    nimsuggestRequestTimeout: initDuration(seconds = 30), 
    nimsuggestSpawnTimeout: initDuration(seconds = 60),
    logNimsuggest: true, 
    inlayHints: NlsInlayHintsConfig(
      typeHints: NlsInlayTypeHintsConfig(
        enable: false
      ),
      exceptionHints: NlsInlayExceptionHintsConfig(
        enable: false, # THIS SHOULD NEVER BE ON!
        hintStringLeft: "🔔",
        hintStringRight: ""
      ),
      parameterHints: NlsInlayParameterHintsConfig(
        enable: false
      ),
    ),
    notificationVerbosity: NlsNotificationVerbosity.nvInfo,
    nimExpandArc: false,
    nimExpandMacro: false,
    
    # delay in ms between file-change and per-file diagnostic check
  )

proc nlsConfigFromJson*(json: JsonNode): NlsConfig =
  ## Build an NlsConfig by overlaying `json` onto defaults.
  ## Missing keys keep their default values; extra keys are ignored.
  result = initDefaultNlsConfig()
  if json.kind != JObject:
    return

  if json.hasKey("performance"):
    let performanceKind = json["performance"].to(PerformanceSettingKind)
    result.performance = performanceSettings[performanceKind]
    
  if json.hasKey("formatOnSave"):
    result.formatOnSave = json["formatOnSave"].getBool()

  # if json.hasKey("fileCheckDelay"):
  #   result.fileCheckDelay = initDuration(milliseconds = json["fileCheckDelay"].getInt())

  if json.hasKey("maxNimsuggestProcesses"):
    result.maxNimsuggestProcesses = json["maxNimsuggestProcesses"].getInt()
  if json.hasKey("maxNimsuggestCrashRetries"):
    result.maxNimsuggestCrashRetries = json["maxNimsuggestCrashRetries"].getInt()
  if json.hasKey("nimsuggestPath"):
    result.nimsuggestPath = FilePathAbs(json["nimsuggestPath"].getStr())
  if json.hasKey("nimsuggestIdleTimeout"):
    result.nimsuggestIdleTimeout = initDuration(seconds = json["nimsuggestIdleTimeout"].getInt())
  if json.hasKey("nimsuggestSpawnTimeout"):
    result.nimsuggestSpawnTimeout = initDuration(seconds = json["nimsuggestSpawnTimeout"].getInt())
  if json.hasKey("nimsuggestRequestTimeout"):
    result.nimsuggestRequestTimeout = initDuration(seconds = json["nimsuggestRequestTimeout"].getInt())
  if json.hasKey("logNimsuggest"):
    result.logNimsuggest = json["logNimsuggest"].getBool()
  if json.hasKey("nimExpandArc"):
    result.nimExpandArc = json["nimExpandArc"].getBool()
  if json.hasKey("nimExpandMacro"):
    result.nimExpandMacro = json["nimExpandMacro"].getBool()
  if json.hasKey("notificationVerbosity"):
    try:
      result.notificationVerbosity = json["notificationVerbosity"].to(NlsNotificationVerbosity)
    except CatchableError:
      discard  # keep default if value is unrecognised
  if json.hasKey("inlayHints") and json["inlayHints"].kind == JObject:
    let ih = json["inlayHints"]
    let hints = result.inlayHints   # ref — mutate in place
    if ih.hasKey("typeHints") and ih["typeHints"].kind == JObject:
      if ih["typeHints"].hasKey("enable"):
        hints.typeHints.enable = ih["typeHints"]["enable"].getBool()
    if ih.hasKey("parameterHints") and ih["parameterHints"].kind == JObject:
      if ih["parameterHints"].hasKey("enable"):
        hints.parameterHints.enable = ih["parameterHints"]["enable"].getBool()
    if ih.hasKey("exceptionHints") and ih["exceptionHints"].kind == JObject:
      let eh = ih["exceptionHints"]
      if eh.hasKey("enable"):
        hints.exceptionHints.enable = eh["enable"].getBool()
      if eh.hasKey("hintStringLeft"):
        hints.exceptionHints.hintStringLeft = eh["hintStringLeft"].getStr()
      if eh.hasKey("hintStringRight"):
        hints.exceptionHints.hintStringRight = eh["hintStringRight"].getStr()

proc parseDidChangeConfiguration*(conf: JsonNode): NlsConfig =
  ## Parses a workspace/didChangeConfiguration push notification.
  ## Expected format: {"settings": {"nimTortoise": {...}}} or {"settings": {"nim": {...}}}
  try:
    if conf.kind == JObject and conf["settings"].kind == JObject:
      let settings = conf["settings"]
      if settings.hasKey("nimTortoise"):
        return nlsConfigFromJson(settings["nimTortoise"])
  except CatchableError:
    debug "Failed to parse didChangeConfiguration payload.", error = getCurrentExceptionMsg()
  return initDefaultNlsConfig()

proc parseWorkspaceConfigurationResponse*(conf: JsonNode): Option[NlsConfig] =
  ## Parses the response to a workspace/configuration request (pull model).
  ## Expected format: [<nimTortoise section>] — single element array.
  try:
    let items = if conf.kind == JArray: conf else: newJArray()
    if items.len == 0:
      return none(NlsConfig)
    if items[0].kind != JObject:
      return none(NlsConfig)
    var cfg = nlsConfigFromJson(items[0])
    return some(cfg)
    
  except CatchableError:
    debug "Failed to parse workspace/configuration response.", error = getCurrentExceptionMsg()
    return none(NlsConfig)

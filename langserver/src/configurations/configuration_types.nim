import std/[times]
import chronos
import forest

type
  NlsNimsuggestConfig* = ref object of RootObj
    projectFile*: string
    fileRegex*: string

  NlsWorkingDirectoryMaping* = ref object of RootObj
    projectFile*: string
    directory*: string

  NlsInlayTypeHintsConfig* = ref object of RootObj
    enable*: bool

  NlsInlayExceptionHintsConfig* = ref object of RootObj
    enable*: bool
    hintStringLeft*: string
    hintStringRight*: string

  NlsInlayParameterHintsConfig* = ref object of RootObj
    enable*: bool

  NlsInlayHintsConfig* = ref object of RootObj
    typeHints*:       NlsInlayTypeHintsConfig
    exceptionHints*:  NlsInlayExceptionHintsConfig
    parameterHints*:  NlsInlayParameterHintsConfig

  NlsNotificationVerbosity* = enum
    nvNone = "none"
    nvError = "error"
    nvWarning = "warning"
    nvInfo = "info"

type
  PerformanceSetting* = object
    kind*: PerformanceSettingKind
    fileCheckThrottling*: times.Duration # File 
    updateOnChange*: bool
    description*: string

  PerformanceSettingKind* {.pure.} = enum
    HIGHEST = "HIGHEST",
    HIGH = "HIGH",
    LOW = "LOW",
    LOWEST = "LOWEST"

type
  NlsConfig* = ref object of RootObj
    # --- Save Settings ---
    # checkOnSave*: bool
    # checkDependentsOnChange*: bool
    performance*: PerformanceSetting
    formatOnSave*: bool
    # --- Langserver settings --- 
    # langserverTimeout*: int
    # fileCheckDelay*: times.Duration # In milliseconds 
    # -- Nimsuggest Settings ---
    nimsuggestPath*: FilePathAbs
    maxNimsuggestProcesses*: int
    maxNimsuggestCrashRetries*: int
    nimsuggestSpawnTimeout*: times.Duration # in seconds
    nimsuggestIdleTimeout*: times.Duration # In seconds
    nimsuggestRequestTimeout*: times.Duration # In seconds
    logNimsuggest*: bool
    inlayHints*: NlsInlayHintsConfig
    notificationVerbosity*: NlsNotificationVerbosity
    nimExpandArc*: bool
    nimExpandMacro*: bool
      
type
  LanguageServerConfigurations* = object
    currentConfig*: NlsConfig
      ## Parsed config. none until first workspace/configuration response arrives.
    configReady*: AsyncEvent
      ## Fired when currentConfig is first populated, and re-fired after each change.



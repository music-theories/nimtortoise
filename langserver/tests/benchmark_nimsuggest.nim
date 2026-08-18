import std/[options, sets, tables, sequtils, strutils, strformat, times]
import chronos
import chronos/asyncproc
import chronicles
import nimtortoise


# NO PATH / NIMBLE AS WORKING DIR

proc benchmarkNimsuggest(
  spawnInfo: NimsuggestSpawnInfo,
  capabilities: set[NimsuggestCapability],
  enableLog: bool,
  enableExceptionInlayHints: bool,
) {.async.} =
  let nimsuggestSettings = NimsuggestSettings(
    exePath: FilePathAbs("nimsuggest"),
    protocol: 4,
    capabilities: capabilities
  )

  let spawnTimeoutMs = 60_000

  let startTime = now()
  info "Nimsuggest started spawn"
  var ns: NimSuggest
  try:
    ns = await createNimsuggest(
      spawnInfo,
      nimsuggestSettings,
      spawnTimeoutMs,
      enableLog,
      enableExceptionInlayHints,
      onProcessStart = proc(p: AsyncProcessRef) {.gcsafe, raises: [].} = discard
    )
    let elapsed = now() - startTime
    info "Nimsuggest spawned successfully",
      port = ns.port,
      elapsed = $elapsed

  except CatchableError as ex:
    let elapsed = now() - startTime
    error "createNimsuggest failed",
      entryPoint = spawnInfo.entryPoint,
      msg = ex.msg,
      elapsed = $elapsed

let addressToTest = FilePathAbs("/Users/dp/Desktop/funis/funis/controller/user_interfaces/src/melody_ui/melody_ui_left.nim")
let nimbleDir = DirPathAbs("/Users/dp/Desktop/funis/funis/controller/user_interfaces")
let nimbleFile = FilePathAbs("/Users/dp/Desktop/funis/funis/controller/user_interfaces/user_interfaces.nimble")

let noPathsSpawnInfo = NimsuggestSpawnInfo(
  entryPoint: addressToTest,
  workingDir: nimbleDir,
  nimbleFile: some(nimbleFile),
  paths: @[],
  # extraArgs: @["--skipParentCfg", "--noNimblePath"]
  extraArgs: @[],
)

waitFor benchmarkNimsuggest(
  noPathsSpawnInfo, 
  {nsCon, nsExceptionInlayHints, nsUnknownFile},
  enableLog = true,
  enableExceptionInlayHints = false
)



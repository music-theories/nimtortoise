import std/[options, tables, sets, strformat, times, json, sequtils, strutils]
import chronos
import chronos/asyncproc
import chronicles
import forest

import ./[suggestapi, suggestapi_types, nimsuggest_types]
export NimsuggestSpawnTimeoutError
import ../configurations/configurations
import ../nimble/nimble_utils
import ../protocol/types
import ../utils/process_utils

proc addSlot*(pool: NimsuggestPool, slot: NimsuggestSlot) =
  pool.slots[slot.spawnInfo.entryPoint] = slot

proc removeSlot*(pool: NimsuggestPool, entryPoint: FilePathAbs) =
  pool.slots.del(entryPoint)

proc canSpawn*(pool: NimsuggestPool): bool =
  pool.maxSlots == 0 or pool.slots.len < pool.maxSlots

proc slotForUri*(pool: NimsuggestPool, uri: FileUri): Option[NimsuggestSlot] =
  for slot in pool.slots.values:
    if uri in slot.ownedUris:
      return some(slot)
  return none(NimsuggestSlot)

# proc assignUri*(slot: NimsuggestSlot, uri: FileUri) =
#   slot.ownedUris.incl(uri)

# proc unassignUri*(slot: NimsuggestSlot, uri: FileUri) =
#   slot.ownedUris.excl(uri)

# === UTILS ===
proc isLive*(slot: NimsuggestSlot): bool =
  slot.state == SlotState.READY

proc isActive*(slot: NimsuggestSlot): bool =
  ## Live or currently starting up. Counts against maxSlots.
  slot.state in {SlotState.SPAWNING, SlotState.READY}

proc ownsUri*(slot: NimsuggestSlot, uri: FileUri): bool =
  uri in slot.ownedUris

proc resolvedNs*(slot: NimsuggestSlot): Option[NimSuggest] =
  ## Returns the live NimSuggest if the slot is ready, else none.
  if slot.state == SlotState.READY:
    return some(slot.ns.read)
  none(NimSuggest)

proc attemptCrashRespawn*(
  pool: NimsuggestPool,
  slot: NimsuggestSlot,
  config: NlsConfig
): Future[bool] {.async.} =
  slot.state = SlotState.CRASHED
  slot.ns = newFuture[NimSuggest]("attemptCrashRespawn")
  inc slot.crashCount
  if slot.crashCount <= config.maxNimsuggestCrashRetries:
    let backoffMs = if slot.crashCount > 0:
      min(1_000 * (1 shl min(slot.crashCount - 1, 14)), 30_000)
    else: 0
    if backoffMs > 0:
      await sleepAsync(backoffMs)
    # Do NOT call execStop here: execStop adds a CLOSE_MAILBOX sentinel to the
    # slot's mailbox, which would cause the processNimsuggestQueries drain loop
    # (our caller) to exit after respawn, leaving the newly-live slot without a
    # consumer. The nimsuggest process is already dead (project.failed was true),
    # so we just reset state directly — no sentinel needed.
    slot.state = SlotState.STOPPED
    slot.crashedUris.clear() # explicit restart = clean slate
    debug "attemptCrashRespawn: calling createNimsuggest",
      projectFile = slot.spawnInfo.entryPoint, 
      attempt = slot.crashCount + 1

    # Use a longer timeout for spawn than for queries: cold compilation of large
    # projects (chronos, chronicles, etc.) can legitimately take > 30s.
    # NimsuggestSpawnTimeoutError still breaks the loop immediately so infinite-
    # loop bugs (e.g. flatty/fieldPairs on recursive types) escape in ≤ spawnMs.
    let spawnTimeoutMs = int(inMilliseconds(config.nimsuggestSpawnTimeout))
    try:
      let ns = await createNimsuggest(
        slot.spawninfo,
        pool.nimsuggest,
        spawnTimeoutMs,
        config.logNimsuggest,
      )

      debug "attemptCrashRespawn: createNimsuggest succeeded", 
        entryPoint = slot.spawnInfo.entryPoint, port = ns.port

      slot.ns.complete(ns)
      slot.state = SlotState.READY
      slot.crashCount = 0

      if pool.statusChangedProc != nil:
        pool.statusChangedProc()
      if pool.notifyProc != nil:
        pool.notifyProc("window/logMessage",
          %*{"type": 3, "message": fmt"Nimsuggest restarted from crashed for {slot.spawnInfo.entryPoint}"})
      return true

    except CatchableError as ex:
      inc slot.crashCount
      slot.state = SlotState.CRASHED
      error "attemptCrashRespawn: spawn attempt failed",
        entryPoint = slot.spawnInfo.entryPoint, attempt = slot.crashCount, msg = ex.msg
    
  else:
    error "attemptCrashRespawn: crash limit reached, slot permanently failed",
      entryPoint = slot.spawnInfo.entryPoint, crashCount = slot.crashCount
    if pool.notifyProc != nil:
      pool.notifyProc(
        "window/logMessage",
        %*{
          "type": 1,
          "message": fmt"Nimsuggest for {slot.spawnInfo.entryPoint} failed after {config.maxNimsuggestCrashRetries} attempts.",
        },
      )
    pool.removeSlot(slot.spawnInfo.entryPoint)
    return false

# === EXECS ===

proc publishNimCheckDiagnostics*(
  output: string,
  notifyProc: proc(name: string, params: JsonNode) {.gcsafe, raises: [].},
) =
  ## Parses raw `nim check` output and publishes errors as LSP diagnostics.
  ## Skips stdlib/nimble-cache paths, instantiation context lines, and warnings.
  if notifyProc == nil or output.len == 0:
    return

  type Entry = tuple[filePath: string, line, col: int, message: string]
  var entries: seq[Entry] = @[]
  var cur: Option[Entry] = none(Entry)

  proc flush() =
    if cur.isSome:
      entries.add(cur.get())
      cur = none(Entry)

  for rawLine in output.splitLines():
    let nimIdx = rawLine.find(".nim(")
    if nimIdx > 0:
      let filePath = rawLine[0 .. nimIdx + 3]          # up to and including ".nim"
      let afterPath = rawLine[nimIdx + 4 .. ^1]        # "(line, col) Error: msg"
      let closeParen = afterPath.find(')')
      if closeParen < 0: flush(); continue

      let coordStr = afterPath[1 ..< closeParen]       # "line, col"
      let afterCoord = afterPath[closeParen + 1 .. ^1] # " Error: msg"

      let coords = coordStr.split(", ")
      if coords.len != 2: flush(); continue
      var lineNum, colNum: int
      try:
        lineNum = coords[0].parseInt
        colNum  = coords[1].parseInt
      except ValueError:
        flush(); continue

      flush()

      if ".choosenim" in filePath or "/.nimble/pkgs" in filePath:
        continue
      if "template/generic instantiation" in afterCoord:
        continue
      let errIdx = afterCoord.find(" Error: ")
      if errIdx < 0:
        continue

      cur = some((filePath, lineNum, colNum, afterCoord[errIdx + 8 .. ^1]))

    else:
      # Continuation line (type mismatch details, spell candidates, etc.)
      if cur.isSome and rawLine.len > 0 and not rawLine.startsWith("SIGSEGV"):
        var e = cur.get()
        e.message &= "\n" & rawLine
        cur = some(e)

  flush()

  # Group by file and publish one notification per file
  var byFile = initTable[string, seq[Entry]]()
  for e in entries:
    byFile.mgetOrPut(e.filePath, @[]).add(e)

  for filePath, fileDiags in byFile:
    var diagArray = newJArray()
    for d in fileDiags:
      diagArray.add(%*{
        "range": {
          "start": {"line": max(0, d.line - 1), "character": max(0, d.col - 1)},
          "end":   {"line": max(0, d.line - 1), "character": max(0, d.col)},
        },
        "severity": 1,
        "source": "nim check",
        "message": d.message.strip(),
      })
    notifyProc("textDocument/publishDiagnostics",
      %*{"uri": string(toUri(FilePathAbs(filePath))), "diagnostics": diagArray})

proc runNimCheckAfterCrash(
  nimExe: FilePathAbs,
  entryPoint: FilePathAbs,
  paths: seq[DirPathAbs],
): Future[string] {.async.} =
  if not string(entryPoint).endsWith(".nim"):
    return
  var args = @["check", "--hints:off"]
  # for p in paths:
  #   args.add("--path:" & string(p))
  args.add(string(entryPoint))
  try:
    debug "runNimCheckAfterCrash: running..."
    let process = await startProcess(
      string(nimExe),
      string(parentDir(entryPoint)),
      arguments = args,
      options = {UsePath},
      stdoutHandle = AsyncProcess.Pipe,
      stderrHandle = AsyncProcess.Pipe,
    )
    let (output, errOutput, _) = await readOutputUntilExit(process, chronos.seconds(30))
    await process.closeWait()
    let combined = (output & errOutput).strip()
    return combined
  except CatchableError as e:
    debug "runNimCheckAfterCrash: failed", msg = e.msg
    return "nim check failed."

proc spawnNewNimsuggestSlot*(
  pool: NimsuggestPool,
  spawningInfo: NimsuggestSpawnInfo,
  nimsuggestSettings: NimsuggestSettings,
  dependencies: Forest,
  config: NlsConfig,
): Future[Option[NimsuggestSlot]] {.async.} =
  ## Returns a NimsuggestSlot if successfully spawned.
  if spawningInfo.entryPoint in pool.slots and pool.slots[spawningInfo.entryPoint].isActive():
    debug "spawnNewNimsuggestSlot: slot already exists and is active, skipping", slot = spawningInfo.entryPoint
    return none(NimsuggestSlot)

  let newSlot = NimsuggestSlot(
    state: SlotState.SPAWNING,
    spawnInfo: spawningInfo,
    spawnProcess: none(AsyncProcessRef),
    ownedUris: initHashSet[FileUri](),
    crashedUris: initHashSet[FileUri](),
    ns: newFuture[NimSuggest]("spawnNewNimsuggestSlot"),
    queryMailbox: newAsyncQueue[NimsuggestQuery[LspFilePosition]](),
    crashCount: 0
  )

  pool.slots[newSlot.spawnInfo.entryPoint] = newSlot

  debug "spawnNewNimsuggestSlot: calling createNimsuggest",
    projectFile = newSlot.spawnInfo.entryPoint
  # Use a longer timeout for spawn than for queries: cold compilation of large
  # projects (chronos, chronicles, etc.) can legitimately take > 30s.
  # NimsuggestSpawnTimeoutError still surfaces immediately so infinite-loop bugs
  # (e.g. flatty/fieldPairs on recursive types) escape in ≤ spawnTimeoutMs.
  let spawnTimeoutMs = int(inMilliseconds(config.nimsuggestSpawnTimeout))
  try:
    let ns = await createNimsuggest(
      spawningInfo, nimsuggestSettings,
      spawnTimeoutMs,
      config.logNimsuggest,
      onProcessStart = proc(p: AsyncProcessRef) {.gcsafe, raises: [].} =
        newSlot.spawnProcess = some(p),
    )
    debug "spawnNewNimsuggestSlot: createNimsuggest succeeded",
      projectFile = newSlot.spawnInfo.entryPoint, 
      port = ns.port

    newSlot.ns.complete(ns)
    newSlot.state = SlotState.READY

    if pool.statusChangedProc != nil:
      pool.statusChangedProc()
    if pool.notifyProc != nil:
      pool.notifyProc("window/logMessage",
        %*{"type": 3, "message": fmt"Nimsuggest initialized for {newSlot.spawnInfo.entryPoint}"})
    return some(newSlot)

  except NimsuggestSpawnTimeoutError as ex:
    newSlot.state = SlotState.CRASHED
    let timeoutSecs = int(inSeconds(config.nimsuggestSpawnTimeout))

    error "spawnNewNimsuggestSlot: timed out",
      projectFile = newSlot.spawnInfo.entryPoint, timeoutSecs = timeoutSecs, 
      msg = ex.msg

    if pool.notifyProc != nil:
      pool.notifyProc("window/logMessage", %*{
        "type": 2,
        "message": fmt"Nimsuggest for {newSlot.spawnInfo.entryPoint} timed out after {timeoutSecs}s. " &
        "If this is a large project, try increasing nimTortoise.nimsuggestSpawnTimeout.",
      })

  except CatchableError as ex:
    newSlot.state = SlotState.CRASHED
    error "spawnNewNimsuggestSlot: spawn failed",
      projectFile = newSlot.spawnInfo.entryPoint, 
      msg = ex.msg

    if pool.notifyProc != nil and ex.msg.len > 0:
      debug "SHOW MESSAGE RUNNING"
      let crashDetail = "Project: " & string(newSlot.spawnInfo.entryPoint) &
        "\nError: " & ex.msg &
        "\n\nNimsuggest crashed catastrophically while spawning. This is probably due to your code generating a SIGSEGV or similar error, meaning nimsuggest is unable to compile it. As a fall-back, the language server will now try to run `nim check` to generate diagnostics while you fix this error."

      pool.notifyProc("window/showMessage",
        %*{"type": 1, "message": "Nimsuggest crashed.", "detail": crashDetail}
      )

    let nimCheckResponse = await runNimCheckAfterCrash(
      dependencies.nim.nimExe,
      newSlot.spawnInfo.entryPoint,
      paths = @[],
    )
    debug "nimCheckResponse", response = nimCheckResponse
    publishNimCheckDiagnostics(nimCheckResponse, pool.notifyProc)

  newSlot.ns.fail(newException(CatchableError,
    fmt"Nimsuggest for {newSlot.spawnInfo.entryPoint} failed to spawn"))

  pool.slots.del(newSlot.spawnInfo.entryPoint)
  return none(NimsuggestSlot)

proc spawnNewNimsuggestSlot*(
  pool: NimsuggestPool,
  fileToSpawnFrom: FilePathAbs,
  rootFolder: DirPathAbs,
  nimsuggestSettings: NimsuggestSettings,
  dependencies: Forest,
  config: NlsConfig,
): Future[Option[NimsuggestSlot]] {.async.} =
  ## Returns a NimsuggestSlot if successfully spawned.
  let spawningInfo: NimsuggestSpawnInfo = getNimsuggestSpawnInfo(
    fileToSpawnFrom, rootFolder, dependencies
  )
  return await spawnNewNimsuggestSlot(
    pool, spawningInfo, 
    nimsuggestSettings, dependencies, config
  )

proc stopNimsuggestSlot*(
  pool: NimsuggestPool, slot: NimsuggestSlot
): Future[bool] {.async.} =
  ## Shut down the slot's nimsuggest process.
  ## ownedUris is NOT cleared — they transfer to the next spawn.
  ## In-flight queries complete with @[] because the TCP socket closes.
  ## Returns true if the slot is stopped, false if the stop proc raised.
  debug "stopNimsuggestSlot", entryPoint = slot.spawnInfo.entryPoint

  var noOfChecks = 50
  case slot.state
  of SlotState.STOPPING:
    # Another coroutine is already stopping this slot — wait for it to finish.
    debug "stopNimsuggestSlot: nimsuggest is already STOPPING ", projectFile = slot.spawnInfo.entryPoint
    while slot.state == SlotState.STOPPING and noOfChecks < 50:
      await sleepAsync(10)
      noOfChecks += 1
    debug "stopNimsuggestSlot: nimsuggest STOPPED", noOfChecks = noOfChecks
    return true

  of SlotState.SPAWNING:
    # processNimsuggestQueries has not started yet — no sentinel consumer exists.
    # Mark stopped, then SIGKILL the process group so a stuck nimsuggest
    # (e.g. infinite loop in the Nim compiler) does not outlive us.
    debug "stopNimsuggestSlot: slot is SPAWNING, marking STOPPED and killing process group",
      projectFile = slot.spawnInfo.entryPoint
    slot.state = SlotState.STOPPED
    when defined(posix):
      if slot.spawnProcess.isSome:
        let pid = slot.spawnProcess.get().processID()
        debug "stopNimsuggestSlot: sending SIGKILL to process group", pid = pid
        killProcessGroup(pid)
    return true

  of SlotState.READY, SlotState.CRASHED:
    debug "stopNimsuggestSlot: stopping nimsuggest slot", projectFile = slot.spawnInfo.entryPoint
    slot.state = SlotState.STOPPING
    let shutdownFut = newFuture[void]("shutdown")
    slot.queryMailbox.addLastNoWait(NimsuggestQuery[LspFilePosition](
      kind: NimsuggestQueryKind.SHUTDOWN,
      responseFuture: newFuture[seq[Suggest]]("shutdown"),
      shutdownFuture: shutdownFut,
    ))
    slot.state = SlotState.STOPPED
    await shutdownFut
    debug "stopNimsuggestSlot: nimsuggest stopped successfully ", projectFile = slot.spawnInfo.entryPoint
    return true

  of SlotState.STOPPED:
    debug "stopNimsuggestSlot: nimsuggest slot already stopped", entryPoint = slot.spawnInfo.entryPoint
    return true  

proc stopNimsuggestSlotAndRemoveFromPool*(
  pool: NimsuggestPool, slot: NimsuggestSlot
) {.async.} =
  let slotEntryPoint = slot.spawnInfo.entryPoint
  discard await stopNimsuggestSlot(pool, slot)
  pool.slots.del(slotEntryPoint)

proc stopAllNimsuggestSlotsInPool*(pool: NimsuggestPool) {.async.} =
  debug "stopping child nimsuggest processes"
  for slot in pool.slots.values.toSeq:
    discard await pool.stopNimsuggestSlot(slot)

proc stopAllNimsuggestSlotsInPoolP*(pool: NimsuggestPool) =
  waitFor pool.stopAllNimsuggestSlotsInPool()


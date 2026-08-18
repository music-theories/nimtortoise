import std/[options, tables, sets, strformat, times, json, sequtils]
import chronos
import chronicles
import forest 

import ./[suggestapi, suggestapi_types, nimsuggest_types]
import ../configurations/configurations
import ../nimble/nimble_utils
import ../protocol/types

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

proc assignUri*(slot: NimsuggestSlot, uri: FileUri) =
  slot.ownedUris.incl(uri)

proc unassignUri*(slot: NimsuggestSlot, uri: FileUri) =
  slot.ownedUris.excl(uri)

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
    debug "execSpawn: calling createNimsuggest",
      projectFile = slot.spawnInfo.entryPoint, 
      attempt = slot.crashCount + 1

    try:
      let ns = await createNimsuggest(
        slot.spawninfo, 
        pool.nimsuggest,
        int(inMilliseconds(config.nimsuggestRequestTimeout)),
        config.logNimsuggest,
        config.inlayHints.exceptionHints.enable
      )

      debug "execSpawn: createNimsuggest succeeded", 
        entryPoint = slot.spawnInfo.entryPoint, port = ns.port

      slot.ns.complete(ns)
      slot.state = SlotState.READY
      slot.crashCount = 0
      slot.lastCmdTime = now()

      if pool.statusChangedProc != nil:
        pool.statusChangedProc()
      if pool.notifyProc != nil:
        pool.notifyProc("window/logMessage",
          %*{"type": 3, "message": fmt"Nimsuggest restarted from crasged for {slot.spawnInfo.entryPoint}"})
      return true

    except CatchableError as ex:
      inc slot.crashCount
      slot.state = SlotState.CRASHED
      error "execSpawn: spawn attempt failed",
        entryPoint = slot.spawnInfo.entryPoint, attempt = slot.crashCount, msg = ex.msg
    
  else:
    error "processQueries: crash limit reached, slot permanently failed",
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

proc spawnNewNimsuggestSlot*(
  pool: NimsuggestPool,
  spawningInfo: NimsuggestSpawnInfo,
  nimsuggestSettings: NimsuggestSettings,
  config: NlsConfig,
): Future[Option[NimsuggestSlot]] {.async.} =
  ## Returns a NimsuggestSlot if successfully spawned.
  if spawningInfo.entryPoint in pool.slots and pool.slots[spawningInfo.entryPoint].isActive():
    debug "spawnNewNimsuggestSlot: slot already exists and is active, skipping", slot = spawningInfo.entryPoint
    return none(NimsuggestSlot)

  let newSlot = NimsuggestSlot(
    state: SlotState.SPAWNING,
    spawnInfo: spawningInfo,
    ownedUris: initHashSet[FileUri](),
    crashedUris: initHashSet[FileUri](),
    ns: newFuture[NimSuggest]("spawnNewNimsuggestSlot"),
    queryMailbox: newAsyncQueue[NimsuggestQuery[LspFilePosition]](),
    lastCmdTime: now(),
    crashCount: 0
  )

  pool.slots[newSlot.spawnInfo.entryPoint] = newSlot

  ## Start a nimsuggest process for `newSlot.spawnInfo.entryPoint`, retrying up to MAX_CRASH_RETRIES times.
  ## Returns true if the spawn succeeded, false if all attempts failed.  Then removes slot from pool.
  ## Sets newSlot.state, resolves newSlot.ns.
  while newSlot.crashCount <= config.maxNimsuggestCrashRetries:
    if newSlot.crashCount > 0:
      let backoffMs = min(1_000 * (1 shl min(newSlot.crashCount - 1, 14)), 30_000)
      debug "execSpawn: backing off before retry",
        projectFile = newSlot.spawnInfo.entryPoint, 
        backoffMs = backoffMs, 
        attempt = newSlot.crashCount

      await sleepAsync(backoffMs)

    debug "execSpawn: calling createNimsuggest",
      projectFile = newSlot.spawnInfo.entryPoint, 
      attempt = newSlot.crashCount + 1
    try:
      let ns = await createNimsuggest(
        spawningInfo, nimsuggestSettings,
        int(inMilliseconds(config.nimsuggestRequestTimeout)),
        config.logNimsuggest,
        config.inlayHints.exceptionHints.enable,
      )
      debug "execSpawn: createNimsuggest succeeded", 
        projectFile = newSlot.spawnInfo.entryPoint, port = ns.port

      newSlot.ns.complete(ns)
      newSlot.state = SlotState.READY
      newSlot.crashCount = 0
      newSlot.lastCmdTime = now()

      if pool.statusChangedProc != nil:
        pool.statusChangedProc()
      if pool.notifyProc != nil:
        pool.notifyProc("window/logMessage",
          %*{"type": 3, "message": fmt"Nimsuggest initialized for {newSlot.spawnInfo.entryPoint}"})
      return some(newSlot)

    except CatchableError as ex:
      inc newSlot.crashCount
      newSlot.state = SlotState.CRASHED
      error "execSpawn: spawn attempt failed",
        projectFile = newSlot.spawnInfo.entryPoint, attempt = newSlot.crashCount, msg = ex.msg

  # All retries exhausted.
  error "execSpawn: crash limit reached, slot permanently failed",
    projectFile = newSlot.spawnInfo.entryPoint, 
    crashCount = newSlot.crashCount

  newSlot.ns.fail(newException(CatchableError,
    fmt"Nimsuggest for {newSlot.spawnInfo.entryPoint} failed after {config.maxNimsuggestCrashRetries} attempts"))

  # Delete slot upon failure.
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
    nimsuggestSettings, config
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

  of SlotState.READY, SlotState.SPAWNING, SlotState.CRASHED:
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
): Future[bool] {.async.} =
  let slotEntryPoint = slot.spawnInfo.entryPoint
  let stoppedSlot = await stopNimsuggestSlot(
    pool, slot
  )
  pool.slots.del(slotEntryPoint)
  return stoppedSlot

proc stopAllNimsuggestSlotsInPool*(pool: NimsuggestPool) {.async.} =
  debug "stopping child nimsuggest processes"
  for slot in pool.slots.values.toSeq:
    discard await pool.stopNimsuggestSlot(slot)

proc stopAllNimsuggestSlotsInPoolP*(pool: NimsuggestPool) =
  waitFor pool.stopAllNimsuggestSlotsInPool()


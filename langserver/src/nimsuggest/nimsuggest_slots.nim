import std/[options, tables, os, sets, strformat, times, json, sequtils]
import chronos
import chronicles
import ./[suggestapi, suggestapi_types, suggestapi_queries, nimsuggest_types]
import ../configurations/configurations
import ../nimble/nimble_utils
import ../protocol/types

proc newSlot*(
  projectFile: FilePath, 
  isEntryPoint: bool,# = false, 
  workingDir: FilePath # = getCurrentDir()
): NimsuggestSlot =
  

  return NimsuggestSlot(
    state: SlotState.SPAWNING,
    projectFile: projectFile,
    workingDir: workingDir,
    ownedUris: initHashSet[FileUri](),
    ns: newFuture[NimSuggest]("pending"),
    queryMailbox: newAsyncQueue[NimsuggestQuery[LspFilePosition]](),
    lastCmdTime: now(),
    isEntryPoint: isEntryPoint,
    crashedUris: initHashSet[FileUri](),
  )

proc addSlot*(pool: NimsuggestPool, slot: NimsuggestSlot) =
  pool.slots[slot.projectFile] = slot

proc removeSlot*(pool: NimsuggestPool, projectFile: FilePath) =
  pool.slots.del(projectFile)

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

# === EXECS ===
proc execSpawn*(
  slot: NimsuggestSlot, 
  pool: NimsuggestPool, 
  projectFile: FilePath,
  config: NlsConfig
): Future[bool] {.async.} =
  ## Start a nimsuggest process for `projectFile`, retrying up to MAX_CRASH_RETRIES times.
  ## Returns true if the spawn succeeded, false if all attempts failed.
  ## Sets slot.state, resolves slot.ns, and re-registers all ownedUris on success.
  debug "execSpawn: enter",
    slotProject = slot.projectFile, projectFile = projectFile,
    slotState = $slot.state, isActive = slot.isActive
  if slot.state == SlotState.READY:
    debug "execSpawn: slot already ready, skipping",
      projectFile = slot.projectFile
    return true

  slot.state = SlotState.SPAWNING
  let nsFut = newFuture[NimSuggest]("execSpawn")
  slot.ns = nsFut

  while slot.crashCount <= config.maxNimsuggestCrashRetries:
    if slot.crashCount > 0:
      let backoffMs = min(1_000 * (1 shl min(slot.crashCount - 1, 14)), 30_000)
      debug "execSpawn: backing off before retry",
        projectFile = projectFile, backoffMs = backoffMs, attempt = slot.crashCount
      await sleepAsync(backoffMs)

    debug "execSpawn: calling createNimsuggest",
      projectFile = projectFile, attempt = slot.crashCount + 1
    try:
      let protocolVersion = detectNimsuggestVersion(
        projectFile,
        FilePath(pool.nimsuggestPath),
        FilePath(slot.workingDir),
      )
      let capabilities = getNimsuggestCapabilities(pool.nimsuggestPath)
      let ns = await createNimsuggest(
        projectFile,
        FilePath(pool.nimsuggestPath),
        FilePath(slot.workingDir),
        timeout                   = int(inMilliseconds(config.nimsuggestRequestTimeout)),
        enableLog                 = config.logNimsuggest,
        enableExceptionInlayHints = config.inlayHints.exceptionHints.enable,
        nimPaths                  = findNimblePaths(string(slot.projectFile)),
        protocolVersion           = protocolVersion,
        capabilities              = capabilities,
      )
      debug "execSpawn: createNimsuggest succeeded", projectFile = projectFile, port = ns.port
      nsFut.complete(ns)
      slot.state = SlotState.READY
      slot.crashCount = 0
      slot.lastCmdTime = now()
      if pool.statusChangedProc != nil:
        pool.statusChangedProc()
      if pool.notifyProc != nil:
        pool.notifyProc("window/logMessage",
          %*{"type": 3, "message": fmt"Nimsuggest initialized for {projectFile}"})
      return true

    except CatchableError as ex:
      inc slot.crashCount
      slot.state = SlotState.CRASHED
      error "execSpawn: spawn attempt failed",
        projectFile = projectFile, attempt = slot.crashCount, msg = ex.msg

  # All retries exhausted.
  error "execSpawn: crash limit reached, slot permanently failed",
    projectFile = projectFile, crashCount = slot.crashCount
  nsFut.fail(newException(CatchableError,
    fmt"Nimsuggest for {projectFile} failed after {config.maxNimsuggestCrashRetries} attempts"))
  return false

proc execStop*(slot: NimsuggestSlot, pool: NimsuggestPool): Future[bool] {.async.} =
  ## Shut down the slot's nimsuggest process.
  ## ownedUris is NOT cleared — they transfer to the next spawn.
  ## In-flight queries complete with @[] because the TCP socket closes.
  ## Returns true if the slot is stopped, false if the stop proc raised.
  case slot.state
  of SlotState.STOPPING:
    # Another coroutine is already stopping this slot — wait for it to finish.
    while slot.state == SlotState.STOPPING:
      await sleepAsync(10)
    return true

  of SlotState.READY, SlotState.SPAWNING, SlotState.CRASHED:
    debug "execStop: stopping nimsuggest", projectFile = slot.projectFile
    slot.state = SlotState.STOPPING
    let shutdownFut = newFuture[void]("shutdown")
    slot.queryMailbox.addLastNoWait(NimsuggestQuery[LspFilePosition](
      kind: NimsuggestQueryKind.SHUTDOWN,
      responseFuture: newFuture[seq[Suggest]]("shutdown"),
      shutdownFuture: shutdownFut,
    ))
    slot.state = SlotState.STOPPED
    await shutdownFut
    return true

  of SlotState.STOPPED:
    return true  # already dead; drain loop already exited

proc attemptCrashRespawn*(
  slot: NimsuggestSlot,
  pool: NimsuggestPool,
  config: NlsConfig
): Future[bool] {.async.} =
  slot.state = SlotState.CRASHED
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
    return await execSpawn(slot, pool, slot.projectFile, config)
    
  else:
    error "processQueries: crash limit reached, slot permanently failed",
      projectFile = slot.projectFile, crashCount = slot.crashCount
    if pool.notifyProc != nil:
      pool.notifyProc(
        "window/logMessage",
        %*{
          "type": 1,
          "message": fmt"Nimsuggest for {slot.projectFile} failed after {config.maxNimsuggestCrashRetries} attempts.",
        },
      )
    pool.removeSlot(slot.projectFile)
    return false

proc stopNimsuggestProcesses*(pool: NimsuggestPool) {.async.} =
  debug "stopping child nimsuggest processes"
  for slot in pool.slots.values.toSeq:
    discard await execStop(slot, pool)

proc stopNimsuggestProcessesP*(pool: NimsuggestPool) =
  waitFor pool.stopNimsuggestProcesses()

proc idleSlots*(
  pool: NimsuggestPool,
  config: NlsConfig
): seq[NimsuggestSlot] =
  ## Return slots that have exceeded the idle timeout and have no recently-active
  ## open files. The caller (langserver.nim tick) handles file eviction and
  ## notification, since it has access to files.nim procs.
  let cutoff = times.now() - config.nimsuggestIdleTimeout
  for slot in pool.slots.values.toSeq:
    if slot.isLive() == false:
      continue
    if slot.lastCmdTime > cutoff:
      continue
    result.add(slot)

proc resolvedSlot*(
  pool: NimsuggestPool,
  openFiles: TableRef[FileUri, NlsFileInfo],
  uri: FileUri
): Option[NimsuggestSlot] =
  ## Return the current owning slot for uri, healing a stale fileInfo.slot
  ## pointer if execCheckKnown moved the URI to a different slot since open.
  let fileInfo = openFiles.getOrDefault(uri)
  if fileInfo == nil:
    return none(NimsuggestSlot)
  if not fileInfo.slot.ownsUri(uri):
    let current = pool.slotForUri(uri)
    if current.isNone:
      return none(NimsuggestSlot)
    else:
      fileInfo.slot = current.get()
      return some(fileInfo.slot)

proc nsProtocolVersion*(
  pool: NimsuggestPool,
  openFiles: TableRef[FileUri, NlsFileInfo],
  uri: FileUri
): int =
  ## Returns the nimsuggest protocol version for the slot serving `uri`.
  ## Safe to call synchronously after queryAt/queryFile returns.
  let slotOpt = pool.resolvedSlot(openFiles, uri)
  if slotOpt.isNone:
    return 0
  let nsOpt = slotOpt.get.resolvedNs
  if nsOpt.isNone:
    return 0
  nsOpt.get.protocolVersion



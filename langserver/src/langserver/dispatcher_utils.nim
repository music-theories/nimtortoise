import std/[options, tables, algorithm, sequtils, strutils, times, sets]
import chronos
import chronicles
import forest

import ../nimsuggest/[suggestapi_types, nimsuggest_types, nimsuggest_slots, nimsuggest_utils]
import ../protocol/types
import ./[langserver_types]
import ../utils/utils


func checkNimsuggestKnownResponse*(response: seq[Suggest]): bool = 
  ## Returns if the response indicates the file was known.
  # Checks response[0].forth == "true" — the boolean result comes back as a string in the forth field of a Suggest object.
  if response.len == 0:
    return false
  else:
    return response[0].forth == "true"

proc checkNimsuggestSlotKnowsURI(slot: NimsuggestSlot, uri: FileUri): Future[Option[NimsuggestSlot]] {.async.} =
  case slot.state
  of SlotState.SPAWNING:
    try:
      let nimsuggestInstance: Nimsuggest = await slot.ns
      let knownQuery = NimsuggestQuery[LspFilePosition](
        id: 0.uint,
        kind: NimsuggestQueryKind.KNOWN,
        uri: uri,
        dirtyFile: FilePathAbs(""),
        responseFuture: newFuture[seq[Suggest]]("known"),
      )
      slot.queryMailbox.addLastNoWait(knownQuery)
      let response = await knownQuery.responseFuture
      let isKnown = checkNimsuggestKnownResponse(response)
      if isKnown:
        return some(slot)
      else:
        return none(NimsuggestSlot)
    except CatchableError:
      return none(NimsuggestSlot)

  of SlotState.READY:
    let nimsuggestInstance = slot.ns.read
    let knownQuery = NimsuggestQuery[LspFilePosition](
      id: 0.uint,
      kind: NimsuggestQueryKind.KNOWN,
      uri: uri,
      dirtyFile: FilePathAbs(""),
      responseFuture: newFuture[seq[Suggest]]("known"),
    )
    slot.queryMailbox.addLastNoWait(knownQuery)
    let response = await knownQuery.responseFuture
    let isKnown = checkNimsuggestKnownResponse(response)
    if isKnown:
      return some(slot)
    else:
      return none(NimsuggestSlot)
  of SlotState.STOPPED, SlotState.STOPPING, SlotState.CRASHED:
    return none(NimsuggestSlot)

proc isKnownByANimsuggestSlot*(pool: NimsuggestPool, uri: FileUri): Future[Option[NimsuggestSlot]] {.async.} =
  var futures: seq[Future[Option[NimsuggestSlot]]]

  for slot in pool.slots.values.toSeq:
    futures.add(checkNimsuggestSlotKnowsURI(slot, uri))

  await allFutures(futures)
  var possibleNimsuggestSlots: seq[NimsuggestSlot] = @[]
  for f in futures:
    let res = f.read()
    if res.isSome:
      possibleNimsuggestSlots.add(res.get())

  possibleNimsuggestSlots.sort(proc(a, b: NimsuggestSlot): int = cmp(string(a.spawnInfo.entryPoint), string(b.spawnInfo.entryPoint)))

  if possibleNimsuggestSlots.len > 0:
    return some(possibleNimsuggestSlots[0])
  else:
    return none(NimsuggestSlot)

proc addFileToOpenFiles*(
  ls: LanguageServer, 
  nimsuggestSlot: NimsuggestSlot,
  params: TextDocumentItem
) = 
  let writtenStashFile = writeStashFile(
    ls.files.storageDir, params.uri, params.text
  )
  let fileInfo = initNlsFileInfo(nimsuggestSlot, params)
  nimsuggestSlot.assignUri(params.uri)
  ls.files.openFiles[params.uri] = fileInfo

proc sortNimsuggestByDate(a, b: NimsuggestSlot): int = 
  if a.lastCmdTime == b.lastCmdTime:
    return 0
  elif a.lastCmdTime < b.lastCmdTime:
    return -1
  else:
    return 1

proc getLeastRecentlyUsedNimsuggestSlotInFullPool*(pool: NimsuggestPool): NimsuggestSlot =
  ## Returns the active slot with the oldest lastCmdTime.
  ## Returns nil if no active slots exist.
  let currentTime = now()
  # var nimsuggestInstances = sorted(sortNimsuggestByDate)
  var allSlots: seq[NimsuggestSlot] = @[]
  for slot in pool.slots.values.toSeq:
    allSlots.add(slot)
  let sortedSlots = sorted(allSlots, sortNimsuggestByDate)
  return sortedSlots[0]

proc lruAmong(slots: seq[NimsuggestSlot]): NimsuggestSlot =
  result = slots[0]
  for slot in slots[1..^1]:
    if slot.lastCmdTime < result.lastCmdTime:
      result = slot

proc nimsuggestSlotToEvict*(pool: NimsuggestPool): NimsuggestSlot =
  ## Selects the slot to evict from a full pool.
  ## Priority: CRASHED → STOPPING → READY → SPAWNING.
  ## Within each tier, the least recently used slot is chosen.
  ## Precondition: pool has at least one slot.
  assert pool.slots.len > 0, "nimsuggestSlotToEvict called on empty pool"
  var allCandidates: seq[NimsuggestSlot] = @[]

  ## First check STOPPED
  var stoppedCandidates: seq[NimsuggestSlot] = @[]
  for slot in pool.slots.values:
    if slot.state == SlotState.STOPPED or slot.state == SlotState.STOPPING:
      stoppedCandidates.add(slot)
      allCandidates.add(slot)

  if stoppedCandidates.len > 0:
    return lruAmong(stoppedCandidates)
  
  # Then check CRASHED
  var crashedCandidates: seq[NimsuggestSlot] = @[]
  for slot in pool.slots.values:
    if slot.state == SlotState.CRASHED:
      crashedCandidates.add(slot)
      allCandidates.add(slot)

  if crashedCandidates.len > 0:
    return lruAmong(crashedCandidates)

  # Then check READY slots 
  var readyButEmptyCandidates: seq[NimsuggestSlot] = @[]
  var readyButFullCandidates: seq[NimsuggestSlot] = @[]
  for slot in pool.slots.values:
    if slot.state == SlotState.READY:
      if slot.ownedUris.len == 0:
        readyButEmptyCandidates.add(slot)
      else:
        readyButFullCandidates.add(slot)
      allCandidates.add(slot)
  
  # Prefer READY slots with no owned URIs...
  if readyButEmptyCandidates.len > 0:
    return lruAmong(readyButEmptyCandidates)

  # ... then those that do own URIs...
  if readyButFullCandidates.len > 0:
    return lruAmong(readyButFullCandidates)

  # Then finally, SPAWNING slots (we gotta give them a chance!!!)
  var spawningCandidates: seq[NimsuggestSlot] = @[]
  for slot in pool.slots.values:
    if slot.state == SlotState.SPAWNING:
      spawningCandidates.add(slot)
      allCandidates.add(slot)

  if spawningCandidates.len > 0:
    return lruAmong(spawningCandidates)
  
  return lruAmong(allCandidates)
  # Unreachable if precondition holds, but satisfies the compiler.
  # raiseAssert "nimsuggestSlotToEvict: pool has slots but none matched any state"


proc queryFile*(ls: LanguageServer, uri: FileUri, kind: NimsuggestQueryKind): Future[seq[Suggest]] =
  ## Creates a NimsuggestQuery and enqueues it on the owning slot's query mailbox.
  ## Returns a Future completed by processQueries when nimsuggest responds.
  result = newFuture[seq[Suggest]]("queryFile")
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  if fileInfo == nil:
    result.complete(@[])
    return
  if fileInfo.slot.state in {SlotState.STOPPED, SlotState.CRASHED}:
    result.complete(@[])
    return
  let dirtyFile = uriToStashFilePath(ls.files.storageDir, uri)
  let query = NimsuggestQuery[LspFilePosition](
    kind: kind,
    uri: uri,
    dirtyFile: dirtyFile,
    responseFuture: result,
  )

  fileInfo.slot.queryMailbox.addLastNoWait(query)

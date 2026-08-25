import std/[
  os, macros,
  options,
  sequtils,
  tables, sets,
  json, times
]

import chronos
import json_serialization
import json_rpc/[servers/socketserver]
import chronicles
import forest
import api

import ../protocol/[enums, types]
import ../configurations/configurations
import ../nimsuggest/nimsuggest
import ../utils/utils

import ./[langserver_types]

proc showMessage*(
  ls: LanguageServer, message: string, typ: MessageType
) {.raises: [].} =
  try:
    proc notify() =
      ls.notify("window/showMessage", %*{"type": typ.int, "message": message})

    let verbosity = ls.configurations.currentConfig.notificationVerbosity
    debug "ShowMessage", message = message
    case verbosity
    of nvInfo:
      notify()
    of nvWarning:
      if typ.int <= MessageType.Warning.int:
        notify()
    of nvError:
      if typ == MessageType.Error:
        notify()
    else:
      discard
  except CatchableError:
    discard

proc toPendingRequestStatus(pr: PendingRequest): PendingRequestStatus =
  result.time =
    case pr.state
    of prsOnGoing:
      $(now() - pr.startTime)
    else:
      $(pr.endTime - pr.startTime)
  result.name = pr.name
  result.entryPoint = pr.entryPoint.get(FilePathAbs(""))
  result.state = $pr.state

proc progressSupported*(ls: LanguageServer): bool =
  return ls.capabilities.lspInitializeParams.capabilities.window
    .get(ClientCapabilities_window()).workDoneProgress
    .get(false)

proc progress*(ls: LanguageServer, token, kind: string, title = "") =
  if ls.progressSupported:
    ls.notify("$/progress", %*{"token": token, "value": {"kind": kind, "title": title}})

proc workDoneProgressCreate*(ls: LanguageServer, token: string) =
  if ls.progressSupported:
    discard ls.call("window/workDoneProgress/create", %ProgressParams(token: token))

proc removeCompletedPendingRequests*(
    ls: LanguageServer, 
    maxTimeAfterRequestWasCompleted = initDuration(seconds = 10) # TODO - this setting should probably be in the configuration
) =
  var toRemove = newSeq[uint]()
  for id, pr in ls.messaging.pendingRequests:
    if pr.state != prsOnGoing:
      let passedTime = now() - pr.endTime
      if passedTime > maxTimeAfterRequestWasCompleted:
        toRemove.add id

  for id in toRemove:
    ls.messaging.pendingRequests.del id


proc getLspStatus*(ls: LanguageServer): NimTortoiseServerStatus {.raises: [].} =

  result.extensionCapabilities = ls.capabilities.extensionCapabilities.toSeq()
  result.exe = NimTortoiseExeStatus(
    path: FilePathAbs(getAppFilename()),
    version: LspVersion
  )
  var seenPorts = initHashSet[int]()
  if ls.pool != nil:
    for slot in ls.pool.slots.values:
      try:
        let nsOpt = slot.resolvedNs
        if nsOpt.isSome:
          let ns = nsOpt.get
          if ns.port in seenPorts:
            continue
          seenPorts.incl(ns.port)
          var nsStatus = NimSuggestStatus(
            entryPoint: slot.spawnInfo.entryPoint,
            version: ls.pool.nimsuggest.version,
            protocol: $(ls.pool.nimsuggest.protocol),
            path: $(ls.pool.nimsuggest.exePath),
            port: ns.port,
          )
          for open in slot.ownedUris.toSeq():
            nsStatus.openFiles.add(string(open))
          result.pool.add(nsStatus)
      except CatchableError:
        discard
  for openFile in ls.files.openFiles.keys:
    let openFilePath = toFilePathAbs(openFile)
    result.openFiles.add(openFilePath)

  result.pendingRequests = ls.messaging.pendingRequests.values.toSeq().map(toPendingRequestStatus)
  result.projectErrors = ls.messaging.projectErrors

proc sendStatusChanged*(ls: LanguageServer) {.raises: [].} =
  let status = %*ls.getLspStatus()
  if status != ls.messaging.lastStatusSent:
    ls.notify("extension/statusUpdate", status)
    ls.messaging.lastStatusSent = status

proc addProjectFileToPendingRequest*(
  ls: LanguageServer, id: uint, uri: FileUri
) =
  try:
    if id in ls.messaging.pendingRequests:
      ls.messaging.pendingRequests[id].entryPoint = some(toFilePathAbs(uri))
      ls.sendStatusChanged()
  except CatchableError as e:
    error "addProjectFileToPendingRequest failed", uri = uri, msg = e.msg

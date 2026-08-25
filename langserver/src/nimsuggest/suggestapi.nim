import std/[strformat, strutils, times, deques, options]

import chronos
import chronos/asyncproc
import chronicles

import api

import ../protocol/types
import ../utils/utils
import ../utils/process_utils

import ./[suggestapi_utils, suggestapi_types, suggestapi_queries]

type NimsuggestSpawnTimeoutError* = object of CatchableError
  ## Raised when nimsuggest does not print its port within the configured
  ## timeout. This indicates the Nim compiler is stuck (e.g. infinite loop in
  ## semForObjectFields). Callers should NOT retry with the same --path flags.

proc createNimsuggest*(
  spawningInfo: NimsuggestSpawnInfo,
  nimsuggestSettings: NimsuggestSettings,
  timeout: int,
  enableLog: bool,
  onProcessStart: proc(p: AsyncProcessRef) {.gcsafe, raises: [].} = nil,
): Future[NimSuggest] {.async.} =
  result = NimSuggest(
    timeout: timeout,
    requestQueue: initDeque[SuggestCall](),
    capabilities: nimsuggestSettings.capabilities,
    protocolVersion: nimsuggestSettings.protocol,
  )

  let args = buildNimsuggestArguments(
    spawningInfo,
    nimsuggestSettings,
    enableLog,
  )

  info "Starting nimsuggest:"
  info "- entryPoint ", entryPoint = spawningInfo.entryPoint
  info "- workingDir", workingDir = spawningInfo.workingDir
  # info "- paths", paths = spawningInfo.paths
  info "- args", args = args
  info "- timeout", timeout = timeout

  result.process = await startProcess(
    string(nimsuggestSettings.exePath),
    string(spawningInfo.workingDir),
    arguments = args,
    options = {UsePath, ProcessGroup},
    stdoutHandle = AsyncProcess.Pipe,
    stderrHandle = AsyncProcess.Pipe,
  )

  if onProcessStart != nil:
    onProcessStart(result.process)

  asyncSpawn logNsError(result)
  # let portLine = await result.process.stdoutStream.readLine(sep = "\n")

  let portLineFut = result.process.stdoutStream.readLine(sep = "\n")
  let portLineOpt = await process_utils.withTimeout(portLineFut, timeout)
  if portLineOpt.isNone:
    await shutdownChildProcess(result.process)
    result.markFailed(fmt"timeout ({timeout}ms) waiting for nimsuggest port")
    raise newException(NimsuggestSpawnTimeoutError, result.errorMessage)
  let portLine = portLineOpt.get()

  debug "Nimsuggest instance started on port", portLine = portLine
  try:
    result.port = portLine.parseInt
  except ValueError:
    let nextLine = await result.process.stdoutStream.readLine(sep = "\n")
    error "Failed to parse nimsuggest port", portLine = portLine, nextLine = nextLine
    result.markFailed("Failed to parse nimsuggest port: " & portLine)
    await shutdownChildProcess(result.process)
    raise newException(CatchableError, result.errorMessage)

proc processQueue(self: Nimsuggest): Future[void] {.async.} =
  debug "processQueue", size = self.requestQueue.len
  while self.requestQueue.len != 0:
    let req = self.requestQueue.popFirst

    if req.future.finished:
      debug "Call cancelled before executed", command = req.command
      continue
    elif self.failed:
      debug "Nimsuggest is not working, returning empty result...", port = self.port
      req.future.complete(@[])
      continue

    benchmark req.commandString:
      try:
        let ta = initTAddress(&"127.0.0.1:{self.port}")
        let transport = await ta.connect()
        discard await transport.write(req.commandString & "\c\L")

        # Proper timeout: withTimeout from process_utils races readFut against a
        # timer, returning none on expiry. We then close the transport so the
        # abandoned readFut fails at the OS level (freeing the socket), and mark
        # the slot failed so processNimsuggestQueries triggers crash-respawn.
        let readFut = transport.read()
        let dataOpt = await process_utils.withTimeout(readFut, self.timeout)
        if dataOpt.isNone:
          transport.close()
          self.markFailed(fmt"timeout ({self.timeout}ms): {req.commandString}")
          debug "processQueue: timeout", command = req.commandString
          if not req.future.finished:
            req.future.complete(@[])
          continue

        let data = dataOpt.get()
        let content = data.toString()
        var res: seq[Suggest] = @[]

        for lineStr in content.splitLines:
          if lineStr != "":
            case req.command
            of "known":
              # "." is the nimsuggest protocol end-marker, not a result row.
              # Filter it here so callers see length=0 (unknown) not length=1, forth=".".
              # if lineStr != ".":
              let sug = Suggest()
              sug.section = ideKnown
              sug.forth = lineStr
              
              debug "KNOWN RESPONSE ", section = ideKnown, forth = lineStr 
              
              res.add(sug)
              
            of "inlayHints":
              if lineStr == ".": continue
              let val = parseSuggestInlayHint(lineStr)
              res.add(Suggest(inlayHintInfo: val))
            else:
              let sug = parseSuggestDef(lineStr)
              if sug.isSome:
                res.add sug.get

        if content == "":
          self.markFailed("Server crashed/socket closed.")
          debug "Server socket closed"

        if not req.future.finished:
          # debug "Sending result(s)", length = res.len, command = req.commandString
          req.future.complete(res)
          transport.close()
        else:
          debug "Call was cancelled before sending the result", command = req.command
          transport.close()

      except CatchableError as ex:
        debug "processQueue: TCP error", msg = ex.msg
        self.markFailed(ex.msg)
        if not req.future.finished:
          req.future.complete(@[])

  self.processing = false

proc call*(
  self: Nimsuggest,
  command: string,
  file: FilePathAbs,
  dirtyFile: FilePathAbs,
  line: int,
  column: int,
  tag = "",
): Future[seq[Suggest]] =
  result = Future[seq[Suggest]]()
  let commandString =
    if string(dirtyFile) != "":
      fmt "{command} \"{file}\";\"{dirtyFile}\":{line}:{column}{tag}"
    else:
      fmt "{command} \"{file}\":{line}:{column}{tag}"

  self.requestQueue.addLast(
    SuggestCall(commandString: commandString, future: result, command: command)
  )

  if not self.processing:
    self.processing = true
    traceAsyncErrors processQueue(self)

template createFullCommand(command: untyped) {.dirty.} =
  proc command*(
    self: Nimsuggest,
    file: FilePathAbs,
    dirtyfile = FilePathAbs(""),
    line: int, col: int,
    tag = ""
  ): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, line, col, tag)

template createFileOnlyCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest, file: FilePathAbs, dirtyfile = FilePathAbs("")): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, 0, 0)

template createGlobalCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest): Future[seq[Suggest]] =
    return self.call(astToStr(command), FilePathAbs("-"), FilePathAbs(""), 0, 0)

template createRangeCommand(command: untyped) {.dirty.} =
  proc command*(
    self: Nimsuggest,
    file: FilePathAbs,
    dirtyfile = FilePathAbs(""),
    startLine, startCol, endLine, endCol: int,
    extra: string,
  ): Future[seq[Suggest]] =
    return self.call(
      astToStr(command),
      file,
      dirtyfile,
      startLine,
      startCol,
      fmt ":{endLine}:{endCol}{extra}",
    )

# create commands
createFullCommand(sug)
createFullCommand(con)
createFullCommand(def)
createFullCommand(declaration)
createFullCommand(use)
createFullCommand(expand)
createFullCommand(highlight)
createFullCommand(type)
createFileOnlyCommand(chk)
createFileOnlyCommand(chkFile)
createFileOnlyCommand(changed)
createFileOnlyCommand(outline)
createFileOnlyCommand(known)
createFileOnlyCommand(globalSymbols)
createGlobalCommand(recompile)
createRangeCommand(inlayHints)

proc isKnown*(nimsuggest: Nimsuggest, filePath: FilePathAbs): Future[bool] {.async.} =
  let fut = nimsuggest.known(filePath)
  let res = await process_utils.withTimeout(fut, REQUEST_TIMEOUT)
  if res.isNone:
    debug "Timeout reached running [isKnown], assuming the file is known (nimsuggest busy)",
      file = $filePath
    return true
  let sug = res.get()
  if sug.len == 0:
    return false
  debug "isKnown", filePath = $filePath, sug = sug[0].forth
  return sug.len > 0 and sug[0].forth == "true"

import std/[os, osproc, sequtils, sets, streams, strformat, strutils, times, deques, options, json]

import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils

import ../protocol/[enums, types]
import ../utils/utils
import ../utils/process_utils
import ../nimble/nimscript_utils
import ./suggestapi_types

func canHandleUnknown*(ns: Nimsuggest): bool =
  return nsUnknownFile in ns.capabilities

template benchmark*(benchmarkName: string, code: untyped) =
  block:
    debug "Started...", benchmark = benchmarkName
    let t0 = epochTime()
    code
    let elapsed = epochTime() - t0
    let elapsedStr = elapsed.formatFloat(format = ffDecimal, precision = 3)
    debug "CPU Time", benchmark = benchmarkName, time = elapsedStr

func nimSymToLSPKind*(suggest: Suggest): CompletionItemKind =
  case suggest.symKind
  of "skConst": CompletionItemKind.Value
  of "skEnumField": CompletionItemKind.Enum
  of "skForVar": CompletionItemKind.Variable
  of "skIterator": CompletionItemKind.Keyword
  of "skLabel": CompletionItemKind.Keyword
  of "skLet": CompletionItemKind.Value
  of "skMacro": CompletionItemKind.Snippet
  of "skMethod": CompletionItemKind.Method
  of "skParam": CompletionItemKind.Variable
  of "skProc": CompletionItemKind.Function
  of "skResult": CompletionItemKind.Value
  of "skTemplate": CompletionItemKind.Snippet
  of "skType": CompletionItemKind.Class
  of "skVar": CompletionItemKind.Field
  of "skFunc": CompletionItemKind.Function
  else: CompletionItemKind.Property

func nimSymToLSPSymbolKind*(suggest: string): SymbolKind =
  case suggest
  of "skConst": SymbolKind.Constant
  of "skEnumField": SymbolKind.EnumMember
  of "skField": SymbolKind.Field
  of "skIterator": SymbolKind.Function
  of "skConverter": SymbolKind.Function
  of "skLet": SymbolKind.Variable
  of "skMacro": SymbolKind.Function
  of "skMethod": SymbolKind.Method
  of "skProc": SymbolKind.Function
  of "skTemplate": SymbolKind.Function
  of "skType": SymbolKind.Class
  of "skVar": SymbolKind.Variable
  of "skFunc": SymbolKind.Function
  else: SymbolKind.Function


func nimSymDetails*(suggest: Suggest): string =
  case suggest.symKind
  of "skConst":
    "const " & suggest.qualifiedPath.join(".") & ": " & suggest.forth
  of "skEnumField":
    "enum " & suggest.forth
  of "skForVar":
    "for var of " & suggest.forth
  of "skIterator":
    suggest.forth
  of "skLabel":
    "label"
  of "skLet":
    "let of " & suggest.forth
  of "skMacro":
    "macro"
  of "skMethod":
    suggest.forth
  of "skParam":
    "param"
  of "skProc":
    suggest.forth
  of "skResult":
    "result"
  of "skTemplate":
    suggest.forth
  of "skType":
    "type " & suggest.qualifiedPath.join(".")
  of "skVar":
    "var of " & suggest.forth
  else:
    suggest.forth


const failedToken = "::Failed::"

proc parseQualifiedPath*(input: string): seq[string] =
  result = @[]
  var
    item = ""
    escaping = false

  for c in input:
    if c == '`':
      item = item & c
      escaping = not escaping
    elif escaping:
      item = item & c
    elif c == '.':
      result.add item
      item = ""
    else:
      item = item & c

  if item != "":
    result.add item

proc parseSuggestDef*(line: string): Option[Suggest] =
  let tokens = line.split('\t')
  if tokens.len < 8:
    error "Failed to parse: ", line = line
    return none(Suggest)
  var sug = Suggest(
    qualifiedPath: tokens[2].parseQualifiedPath,
    filePath: FilePath(tokens[4]),
    line: parseInt(tokens[5]),
    column: parseInt(tokens[6]),
    doc: tokens[7].unescape(),
    forth: tokens[3],
    symKind: tokens[1],
    section: parseEnum[IdeCmd]("ide" & capitalizeAscii(tokens[0])),
  )
  if tokens.len == 11:
    sug.endLine = parseInt(tokens[9])
    sug.endCol = parseInt(tokens[10])
  some sug

proc parseSuggestInlayHint*(line: string): SuggestInlayHint =
  let tokens = line.split('\t')
  if tokens.len < 8:
    error "Failed to parse: ", line = line
    raise newException(ValueError, fmt "Failed to parse line {line}")
  result = SuggestInlayHint(
    kind: parseEnum[SuggestInlayHintKind](capitalizeAscii(tokens[0])),
    line: parseInt(tokens[1]),
    column: parseInt(tokens[2]),
    label: tokens[3],
    paddingLeft: parseBool(tokens[4]),
    paddingRight: parseBool(tokens[5]),
    allowInsert: parseBool(tokens[6]),
    tooltip: tokens[7],
  )

proc name*(sug: Suggest): string =
  return sug.qualifiedPath[^1]

proc markFailed*(self: NimSuggest, errMessage: string) {.raises: [].} =
  if self.failed:
    return
  self.failed = true
  self.errorMessage = errMessage

proc toString*(bytes: openarray[byte]): string =
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(result[0].addr, bytes[0].unsafeAddr, bytes.len)

proc logNsError*(ns: NimSuggest) {.async.} =
  let err = string.fromBytes(await ns.process.stderrStream.read())
  if err.len == 0:
    return
  error "NimSuggest Error (stderr)", err = err
  ns.markFailed(err)

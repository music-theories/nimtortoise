import std/[strutils, options]

# ── Internal helpers ──────────────────────────────────────────────────────────

proc extractLastType(s: string): string =
  ## Return the text after the last `: ` at bracket-depth 0.
  ## E.g. "blockSize = 5.0: blockSize: float64"  →  "float64"
  ##      "node: NestedNode[A, B]"                →  "NestedNode[A, B]"
  var depth = 0
  var lastColon = -1
  var i = 0
  while i < s.len:
    case s[i]
    of '[', '(':
      inc depth
    of ']', ')':
      if depth > 0: dec depth
    of ':':
      if depth == 0 and i + 1 < s.len and s[i + 1] == ' ':
        lastColon = i
    else:
      discard
    inc i
  if lastColon >= 0:
    return s[lastColon + 2 ..^ 1].strip()
  return s.strip()

proc splitBySemicolon(s: string): seq[string] =
  ## Split by `;` while ignoring `;` inside brackets.
  result = @[]
  var cur = ""
  var depth = 0
  for c in s:
    case c
    of '[', '(':
      inc depth
      cur.add(c)
    of ']', ')':
      if depth > 0: dec depth
      cur.add(c)
    of ';':
      if depth == 0:
        if cur.strip().len > 0:
          result.add(cur.strip())
        cur = ""
      else:
        cur.add(c)
    else:
      cur.add(c)
  if cur.strip().len > 0:
    result.add(cur.strip())

proc extractProcParamTypes(sig: string): seq[string] =
  ## Parse `proc name(p1: T1; p2, p3: T2; ...): Ret` and return one type
  ## entry per argument position (handling comma-grouped names).
  result = @[]
  let openParen = sig.find('(')
  if openParen < 0:
    return
  # Walk to the matching ')' at depth 0.
  var depth = 1
  var closeParen = -1
  for i in openParen + 1 ..< sig.len:
    case sig[i]
    of '[', '(':
      inc depth
    of ']', ')':
      dec depth
      if depth == 0:
        closeParen = i
        break
    else:
      discard
  if closeParen < 0:
    return
  let paramsStr = sig[openParen + 1 ..< closeParen]
  for param in splitBySemicolon(paramsStr):
    # Strip default value:  "name: T = default"  →  "name: T"
    var p = param
    let eqPos = p.find(" = ")
    if eqPos >= 0:
      p = p[0 ..< eqPos].strip()
    # Split "a, b: T" into names and type.
    let colonPos = p.rfind(": ")
    if colonPos < 0:
      result.add(p)
      continue
    let names  = p[0 ..< colonPos]
    let typStr = p[colonPos + 2 ..^ 1].strip()
    let count  = names.split(',').len
    for _ in 0 ..< count:
      result.add(typStr)

proc parseProcLineIndex(line: string): int =
  ## From "[N] proc ..." return N, or -1 if the line doesn't match.
  let stripped = line.strip()
  if stripped.len == 0 or stripped[0] != '[':
    return -1
  let closeB = stripped.find(']')
  if closeB < 0:
    return -1
  try:
    return stripped[1 ..< closeB].parseInt()
  except ValueError:
    return -1

# ── Main parser ───────────────────────────────────────────────────────────────

type
  ParsedMismatch = object
    funcName:     string
    args:         seq[tuple[index: int, actualType: string]]
    mismatchPos:  int   # -1 when not determinable
    expectedType: string

proc tryParseMismatch(msg: string): Option[ParsedMismatch] =
  if "type mismatch" notin msg:
    return none(ParsedMismatch)

  let lines = msg.splitLines()
  var i = 0

  # ── 1. Find the "type mismatch" header line ──────────────────────────────
  while i < lines.len and "type mismatch" notin lines[i]:
    inc i
  if i >= lines.len:
    return none(ParsedMismatch)
  inc i

  # ── 2. Find "Expression:" (possibly continued on indented lines) ─────────
  while i < lines.len and not lines[i].startsWith("Expression:"):
    inc i
  if i >= lines.len:
    return none(ParsedMismatch)

  var exprBuf = lines[i]
  inc i
  # Continuation lines are indented and do NOT start with "[".
  while i < lines.len:
    let l = lines[i]
    if l.len > 0 and l[0] == ' ' and not l.strip().startsWith("["):
      exprBuf.add(l)
      inc i
    else:
      break

  const exprPrefix = "Expression: "
  var funcName = ""
  if exprBuf.startsWith(exprPrefix):
    let content = exprBuf[exprPrefix.len ..^ 1].strip()
    let paren = content.find('(')
    funcName = if paren >= 0: content[0 ..< paren] else: content

  # ── 3. Parse argument lines "[N] ..." ────────────────────────────────────
  var args: seq[tuple[index: int, actualType: string]] = @[]
  while i < lines.len:
    let line = lines[i].strip()
    if not line.startsWith("["):
      break
    let closeB = line.find(']')
    if closeB >= 0:
      try:
        let idx = line[1 ..< closeB].parseInt()
        let rest = line[closeB + 1 ..^ 1].strip()
        args.add((index: idx, actualType: extractLastType(rest)))
      except ValueError:
        discard
    inc i

  if args.len == 0:
    return none(ParsedMismatch)

  # ── 4. Find "Expected one of" section ────────────────────────────────────
  while i < lines.len and lines[i].strip() == "":
    inc i

  # Try to read the mismatch position from "first mismatch at [N]".
  # nimsuggest sometimes emits "[position]" (literal) instead of a number;
  # in that case parseInt fails and we fall through to the proc-line fallback.
  var mismatchPos = -1
  var procSigLines: seq[string] = @[]

  while i < lines.len:
    let line = lines[i]

    if "first mismatch at [" in line:
      let marker = "first mismatch at ["
      let start  = line.find(marker) + marker.len
      let finish = line.find(']', start)
      if finish > start:
        try:
          mismatchPos = line[start ..< finish].parseInt()
        except ValueError:
          discard   # literal "position" or similar — handled below
      inc i
      continue

    # Collect the first "[N] proc" signature that appears after the header.
    let stripped = line.strip()
    if stripped.len > 0 and stripped[0] == '[' and " proc " in stripped:
      # Fallback: if we never got a numeric mismatch position from the header,
      # use the number prefixed on this proc line.  In practice nimsuggest
      # labels the best-matching overload with [N] where N == the first
      # mismatching parameter index.
      if mismatchPos < 0:
        mismatchPos = parseProcLineIndex(stripped)

      procSigLines.add(line)
      inc i
      # Continuation lines are indented.
      while i < lines.len and lines[i].len > 0 and lines[i][0] == ' ':
        procSigLines.add(lines[i])
        inc i
      break

    inc i

  # ── 5. Extract expected type at mismatch position ─────────────────────────
  var expectedType = ""
  if procSigLines.len > 0 and mismatchPos > 0:
    let fullSig    = procSigLines.join(" ")
    let paramTypes = extractProcParamTypes(fullSig)
    if mismatchPos <= paramTypes.len:
      expectedType = paramTypes[mismatchPos - 1]

  return some(ParsedMismatch(
    funcName:     funcName,
    args:         args,
    mismatchPos:  mismatchPos,
    expectedType: expectedType,
  ))

# ── Public API ────────────────────────────────────────────────────────────────

proc isExactSplitIdentityTypeMismatch*(doc: string): bool =
  ## Returns true only when the split-identity match is definitive — no module-qualifier
  ## stripping is applied. Safe to use as a trigger for automatic recovery (RECOMPILE).
  ##
  ## Pattern 1: `got 'X' but expected 'X'` with textually identical type strings.
  ## Pattern 2: actualType == expectedType exactly (including any module prefix).
  if "type mismatch" notin doc:
    return false

  # Pattern 1: older "got '...' but expected '...'" wire format
  block:
    const gotPfx = "got '"
    const expPfx = "but expected '"
    let gi = doc.find(gotPfx)
    let ei = doc.find(expPfx)
    if gi >= 0 and ei > gi:
      let gotEnd = doc.find('\'', gi + gotPfx.len)
      let expEnd = doc.find('\'', ei + expPfx.len)
      if gotEnd > gi + gotPfx.len and expEnd > ei + expPfx.len:
        let gotType = doc[gi + gotPfx.len ..< gotEnd]
        let expType = doc[ei + expPfx.len ..< expEnd]
        if gotType == expType:
          return true

  # Pattern 2: "Expression:" / "Expected one of" format — exact match only.
  let parsed = tryParseMismatch(doc)
  if parsed.isSome:
    let p = parsed.get()
    if p.mismatchPos > 0 and p.expectedType.len > 0:
      for arg in p.args:
        if arg.index == p.mismatchPos and arg.actualType == p.expectedType:
          return true

  return false

proc isSplitIdentityTypeMismatch*(doc: string): bool =
  ## Returns true when a diagnostic looks like a split-identity false positive:
  ## a type mismatch where actual and expected refer to the same type name,
  ## with at most a module-qualification difference.
  ##
  ## Two patterns are detected:
  ##   Pattern 1 (older wire format): got 'X' but expected 'X' — identical strings.
  ##   Pattern 2 (Expression format): actualType and expectedType are identical, OR
  ##     actualType is module-qualified and its base name equals the unqualified
  ##     expectedType (e.g. "suggestapi_types.NimsuggestSettings" vs "NimsuggestSettings").
  ##
  ## Pattern 2 loose matching can fire on genuine errors where two distinct types
  ## from different modules share a base name.  The caller must treat a positive
  ## result as advisory only — never as a trigger for destructive action.
  if "type mismatch" notin doc:
    return false

  # Pattern 1: older "got '...' but expected '...'" wire format
  block:
    const gotPfx = "got '"
    const expPfx = "but expected '"
    let gi = doc.find(gotPfx)
    let ei = doc.find(expPfx)
    if gi >= 0 and ei > gi:
      let gotEnd = doc.find('\'', gi + gotPfx.len)
      let expEnd = doc.find('\'', ei + expPfx.len)
      if gotEnd > gi + gotPfx.len and expEnd > ei + expPfx.len:
        let gotType = doc[gi + gotPfx.len ..< gotEnd]
        let expType = doc[ei + expPfx.len ..< expEnd]
        if gotType == expType:
          return true

  # Pattern 2: "Expression:" / "Expected one of" format — reuse existing parser.
  let parsed = tryParseMismatch(doc)
  if parsed.isSome:
    let p = parsed.get()
    if p.mismatchPos > 0 and p.expectedType.len > 0:
      for arg in p.args:
        if arg.index == p.mismatchPos:
          if arg.actualType == p.expectedType:
            return true
          # Module-qualified actual vs unqualified expected with the same base name.
          # e.g. "suggestapi_types.NimsuggestSettings" vs "NimsuggestSettings"
          let dotIdx = arg.actualType.rfind('.')
          if dotIdx >= 0 and arg.actualType[dotIdx + 1 ..^ 1] == p.expectedType:
            return true

  return false

proc formatTypeMismatch*(msg: string): string =
  ## Reformat a nimsuggest "type mismatch" message for cleaner display.
  ##
  ## Input (nimsuggest raw):
  ##   type mismatch
  ##   Expression: foo(longExpr1, longExpr2, ...)
  ##     [1] longExpr1: TypeA
  ##     [4] connectorSize: float64
  ##   Expected one of (first mismatch at [4]):
  ##   [4] proc foo(a: TypeA; ...; d: UIMelodyContainerSizes; ...): Ret
  ##
  ## Output:
  ##   Error: type mismatch
  ##   Expression: foo(
  ##      [1] TypeA
  ##      [2] TypeB
  ##      [3] TypeC
  ##   -> [4] `UIMelodyContainerSizes` should be `float64`
  ##      ...
  ##   )
  ##
  ## Falls back to `msg` unchanged when the format is not recognised.
  let parsed = tryParseMismatch(msg)
  if parsed.isNone:
    return msg
  let p = parsed.get()

  var output: seq[string] = @[
    "Error: type mismatch",
    "Expression: " & p.funcName & "(",
  ]
  for arg in p.args:
    let idxLabel = "[" & $arg.index & "]"
    if arg.index == p.mismatchPos:
      if p.expectedType.len > 0:
        output.add("✗  " & idxLabel & " `" & arg.actualType & "` should be `" & p.expectedType & "`")
      else:
        output.add("✗  " & idxLabel & " " & arg.actualType)
    else:
      output.add("   " & idxLabel & " " & arg.actualType)
  output.add(")")

  return output.join("\n")

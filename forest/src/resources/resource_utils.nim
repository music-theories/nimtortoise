import std/[json, hashes, os, strutils, uri]
import ./resource_types

func `$`*(x: FileUri):     string = string(x)
func `$`*(x: FilePathAbs): string = string(x)
func `$`*(x: FilePathRel): string = string(x)
func `$`*(x: DirPathAbs):  string = string(x)
func `$`*(x: DirPathRel):  string = string(x)

func `==`*(a, b: FileUri):     bool = string(a) == string(b)
func `==`*(a, b: FilePathAbs): bool = string(a) == string(b)
func `==`*(a, b: FilePathRel): bool = string(a) == string(b)
func `==`*(a, b: DirPathAbs):  bool = string(a) == string(b)
func `==`*(a, b: DirPathRel):  bool = string(a) == string(b)


proc hash*(x: FileUri):     Hash = result = string(x).hash; result = !$result
proc hash*(x: FilePathAbs): Hash = result = string(x).hash; result = !$result
proc hash*(x: FilePathRel): Hash = result = string(x).hash; result = !$result
proc hash*(x: DirPathAbs):  Hash = result = string(x).hash; result = !$result
proc hash*(x: DirPathRel):  Hash = result = string(x).hash; result = !$result

proc `%`*(x: FileUri):     JsonNode = %string(x)
proc `%`*(x: FilePathAbs): JsonNode = %string(x)
proc `%`*(x: FilePathRel): JsonNode = %string(x)
proc `%`*(x: DirPathAbs):  JsonNode = %string(x)
proc `%`*(x: DirPathRel):  JsonNode = %string(x)

proc fromJsonHook*(a: var FileUri;     b: JsonNode) = a = FileUri(b.getStr())
proc fromJsonHook*(a: var FilePathAbs; b: JsonNode) = a = FilePathAbs(b.getStr())
proc fromJsonHook*(a: var FilePathRel; b: JsonNode) = a = FilePathRel(b.getStr())
proc fromJsonHook*(a: var DirPathAbs;  b: JsonNode) = a = DirPathAbs(b.getStr())
proc fromJsonHook*(a: var DirPathRel;  b: JsonNode) = a = DirPathRel(b.getStr())

proc toJsonHook*(x: FileUri):     JsonNode = newJString(string(x))
proc toJsonHook*(x: FilePathAbs): JsonNode = newJString(string(x))
proc toJsonHook*(x: FilePathRel): JsonNode = newJString(string(x))
proc toJsonHook*(x: DirPathAbs):  JsonNode = newJString(string(x))
proc toJsonHook*(x: DirPathRel):  JsonNode = newJString(string(x))


# ── path joining (/  operator) ─────────────────────────────────────────────────
## Joining an absolute dir with a relative child yields an absolute result.
## The file/dir distinction of the right-hand side is preserved.
func `/`*(dir: DirPathAbs, rel: FilePathRel): FilePathAbs =
  FilePathAbs(string(dir) / string(rel))

func `/`*(dir: DirPathAbs, rel: DirPathRel): DirPathAbs =
  DirPathAbs(string(dir) / string(rel))

## Joining a relative dir with a relative child stays relative.
func `/`*(dir: DirPathRel, rel: FilePathRel): FilePathRel =
  FilePathRel(string(dir) / string(rel))

func `/`*(dir: DirPathRel, rel: DirPathRel): DirPathRel =
  DirPathRel(string(dir) / string(rel))

# ── parent directory ───────────────────────────────────────────────────────────
func parentDir*(p: FilePathAbs): DirPathAbs =
  DirPathAbs(parentDir(string(p)))

func parentDir*(p: DirPathAbs): DirPathAbs =
  DirPathAbs(parentDir(string(p).strip(chars = {'/'}, leading = false)))

# ── filename / basename ────────────────────────────────────────────────────────
func filename*(p: FilePathAbs): string = lastPathPart(string(p))
func filename*(p: FilePathRel): string = lastPathPart(string(p))

func stem*(p: FilePathAbs): string = splitFile(string(p)).name
func stem*(p: FilePathRel): string = splitFile(string(p)).name

func ext*(p: FilePathAbs): string = splitFile(string(p)).ext
func ext*(p: FilePathRel): string = splitFile(string(p)).ext

# ── FileUri <-> FilePathAbs / DirPathAbs conversions ──────────────────────────
type
  UriParseError* = object of Defect
    uri*: FileUri

proc toUri*(p: FilePathAbs): FileUri =
  ## Encode an absolute file path as an RFC 8089 file:// URI.
  ## Special characters are percent-encoded; on Windows a leading '/' is inserted.
  let s = string(p)
  var output = "file://" & newStringOfCap(s.len + s.len shr 2)
  when defined(windows):
    output.add('/')
  for c in s:
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/':
      output.add(c)
    of '\\':
      when defined(windows):
        output.add('/')
      else:
        output.add('%')
        output.add(toHex(ord(c), 2))
    else:
      output.add('%')
      output.add(toHex(ord(c), 2))
  FileUri(output)

proc toUri*(p: DirPathAbs): FileUri = toUri(FilePathAbs(string(p)))

proc uriToPathString(u: FileUri): string =
  ## Convert an RFC 8089 file URI to a native absolute path string.
  let s = string(u)
  let parsed = parseUri(s)
  if parsed.scheme != "file":
    var e = newException(UriParseError,
      "Invalid scheme in uri \"" & s & "\": " & parsed.scheme &
      ", only \"file\" is supported")
    e.uri = u
    raise e
  if parsed.hostname != "":
    var e = newException(UriParseError,
      "Invalid hostname in uri \"" & s & "\": " & parsed.hostname &
      ", only empty hostname is supported")
    e.uri = u
    raise e
  normalizedPath(
    when defined(windows): parsed.path[1 ..^ 1]
    else:                  parsed.path
  ).decodeUrl()

proc toFilePathAbs*(u: FileUri): FilePathAbs = FilePathAbs(uriToPathString(u))
proc toDirPathAbs*(u: FileUri):  DirPathAbs  = DirPathAbs(uriToPathString(u))

# ── absolutise a relative path against an anchor ───────────────────────────────
func toAbs*(rel: FilePathRel; anchor: DirPathAbs): FilePathAbs =
  FilePathAbs(absolutePath(string(rel), string(anchor)))

func toAbs*(rel: DirPathRel; anchor: DirPathAbs): DirPathAbs =
  DirPathAbs(absolutePath(string(rel), string(anchor)))

# ── relativise an absolute path against an anchor ──────────────────────────────
proc toRel*(p: FilePathAbs; anchor: DirPathAbs): FilePathRel =
  FilePathRel(relativePath(string(p), string(anchor)))

proc toRel*(p: DirPathAbs; anchor: DirPathAbs): DirPathRel =
  DirPathRel(relativePath(string(p), string(anchor)))

# ── directory name (final component of a dir path) ────────────────────────────
func dirName*(p: DirPathAbs): string =
  lastPathPart(string(p).strip(chars = {'/'}, leading = false))

func dirName*(p: DirPathRel): string =
  lastPathPart(string(p).strip(chars = {'/'}, leading = false))

# ── change file extension ──────────────────────────────────────────────────────
func withExt*(p: FilePathAbs; newExt: string): FilePathAbs =
  let (dir, name, _) = splitFile(string(p))
  FilePathAbs(dir / (name & newExt))

func withExt*(p: FilePathRel; newExt: string): FilePathRel =
  let (dir, name, _) = splitFile(string(p))
  FilePathRel(dir / (name & newExt))

# ── reinterpretation casts (use when the FS has told you what a path is) ───────
## These are intentional escape hatches — you are asserting the file/dir nature.
func asFilePathAbs*(p: DirPathAbs):  FilePathAbs = FilePathAbs(string(p))
func asDirPathAbs*(p: FilePathAbs):  DirPathAbs  = DirPathAbs(string(p))
func asFilePathRel*(p: DirPathRel):  FilePathRel = FilePathRel(string(p))
func asDirPathRel*(p: FilePathRel):  DirPathRel  = DirPathRel(string(p))

# ── containment checks ────────────────────────────────────────────────────────
func isInside*(file: FilePathAbs; dir: DirPathAbs): bool =
  ## Returns true if file is inside dir (at any depth).
  ## Normalises both sides so trailing slashes and redundant separators
  ## do not cause false negatives.
  let d = string(dir).normalizedPath & DirSep
  string(file).normalizedPath.startsWith(d)

func isInside*(sub: DirPathAbs; dir: DirPathAbs): bool =
  ## Returns true if sub is a subdirectory of dir (at any depth).
  let d = string(dir).normalizedPath & DirSep
  string(sub).normalizedPath.startsWith(d)


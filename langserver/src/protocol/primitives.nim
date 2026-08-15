import json, options, hashes

type
  FileUri* = distinct string  ## A file:// URI (e.g. "file:///Users/foo/bar.nim")
  FilePath* = distinct string ## A filesystem path (e.g. "/Users/foo/bar.nim")

func `$`*(x: FileUri): string = string(x)
func `$`*(x: FilePath): string = string(x)
func `==`*(a, b: FileUri): bool = string(a) == string(b)
func `==`*(a, b: FilePath): bool = string(a) == string(b)
proc hash*(x: FileUri): Hash = result = string(x).hash; result = !$result
proc hash*(x: FilePath): Hash = result = string(x).hash; result = !$result
proc `%`*(x: FileUri): JsonNode = %string(x)
proc `%`*(x: FilePath): JsonNode = %string(x)
proc fromJsonHook*(a: var FileUri; b: JsonNode) = a = FileUri(b.getStr())
proc fromJsonHook*(a: var FilePath; b: JsonNode) = a = FilePath(b.getStr())

type
  OptionalSeq*[T] = Option[seq[T]]
  OptionalNode* = Option[JsonNode]
  uinteger* = range[0 .. (1 shl 31 - 1)]

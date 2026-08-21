import std/[os, sequtils, strutils, tables]
import chronicles
import ../resources/resources
import ./[forest_utils, forest_types]

proc extractStringSeq(content, key: string): seq[FilePathRel] =
  ## Finds `key = @["a", "b"]` in content (non-comment lines only).
  for line in content.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith('#'): continue
    let keyIdx = trimmed.find(key)
    if keyIdx < 0: continue
    # Verify it's actually this key (not a key that merely contains key as substring)
    let afterKey = trimmed[keyIdx + key.len .. ^1].strip(leading = true, trailing = false)
    if not afterKey.startsWith('='): continue
    let listStart = afterKey.find('@')
    if listStart < 0: continue
    let bracketStart = afterKey.find('[', listStart)
    let bracketEnd = afterKey.find(']', bracketStart + 1)
    if bracketStart < 0 or bracketEnd < 0: continue
    let listContent = afterKey[bracketStart + 1 .. bracketEnd - 1]
    var i = 0
    while i < listContent.len:
      if listContent[i] == '"':
        let endQuote = listContent.find('"', i + 1)
        if endQuote > i:
          result.add(FilePathRel(listContent[i + 1 .. endQuote - 1]))
          i = endQuote + 1
        else:
          break
      else:
        inc i
    return  # found the key, done

proc extractSingleString(content, key: string): FilePathRel =
  ## Finds `key = "value"` in content (non-comment lines only).
  for line in content.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith('#'): continue
    let keyIdx = trimmed.find(key)
    if keyIdx < 0: continue
    let afterKey = trimmed[keyIdx + key.len .. ^1].strip(leading = true, trailing = false)
    if not afterKey.startsWith('='): continue
    let quoteStart = afterKey.find('"')
    if quoteStart < 0: continue
    let quoteEnd = afterKey.find('"', quoteStart + 1)
    if quoteEnd < 0: continue
    return FilePathRel(afterKey[quoteStart + 1 .. quoteEnd - 1])

proc parseNimbleFile*(nimbleFile: FilePathAbs): NimbleDumpInfo =
  ## Reads the .nimble file directly — no subprocess.
  result.name = splitFile(string(nimbleFile)).name
  let content = readFile(string(nimbleFile))
  result.srcDir         = DirPathRel(string(extractSingleString(content, "srcDir")))
  result.bin            = extractStringSeq(content, "bin")
  result.entryPoints    = extractStringSeq(content, "entryPoints")
  result.testEntryPoint = extractSingleString(content, "testEntryPoint")
  # Synthesise entry points from srcDir + bin (mirrors what Nimble itself does)
  for binEntry in result.bin:
    let ep = FilePathRel((string(result.srcDir) / string(binEntry) & ".nim").normalizedPath)
    if ep notin result.entryPoints:
      result.entryPoints.add(ep)

proc getEntryPoints*(
  nimbleFiles: Table[FilePathAbs, NimbleDumpInfo]
): seq[FilePathAbs] =
  result = @[]
  for k, nimbleFile in nimbleFiles:
    let nimbleDir = parentDir(k)
    for ep in nimbleFile.entryPoints:
      let abs = FilePathAbs((string(nimbleDir) / string(ep)).absolutePath.normalizedPath)
      if fileExists(string(abs)):
        result.add(abs)
      else:
        warn "entry point not found, skipping", path = $abs

    if string(nimbleFile.testEntryPoint).len > 0:
      let abs = FilePathAbs((string(nimbleDir) / string(nimbleFile.testEntryPoint)).absolutePath.normalizedPath)
      if fileExists(string(abs)):
        result.add(abs)

  result = deduplicate(result)

proc initNimbleInfo*(
  rootPath: DirPathAbs
): NimbleInfo =
  let allNimbleFiles = getAllFiles(rootPath, "*.nimble")
  var nimbleDumpTable = initTable[FilePathAbs, NimbleDumpInfo]()
  for nimbleFile in allNimbleFiles:
    nimbleDumpTable[nimbleFile] = parseNimbleFile(nimbleFile)
  let allEntryPoints = getEntryPoints(nimbleDumpTable)
  return NimbleInfo(
    files: allNimbleFiles,
    dump: nimbleDumpTable,
    entryPoints: allEntryPoints
  )

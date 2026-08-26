import std/[strutils]

proc getVersionFromNimble(): string =
  #We should static run nimble dump instead
  const content = staticRead("../../nimtortoise.nimble")
  for v in content.splitLines:
    if v.startsWith("version"):
      return v.split("=")[^1].strip(chars = {' ', '"'})
  return "unknown"

const
  LSPVersion* = getVersionFromNimble()
  CRLF* = "\r\n"

const
  CONFIG_WAIT_TIMEOUT_MS* = 30_000
  CONFIG_WAIT_POLL_MS* = 50

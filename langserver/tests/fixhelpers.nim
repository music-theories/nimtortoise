## fixhelpers.nim — compatibility hub for test files.
## Re-exports lspsocketclient + client_utils and adds the two missing procs.

import ./lspsocketclient
import ./client_utils
export lspsocketclient
export client_utils

proc sendDidOpen*(client: LspSocketClient, relPath: string) =
  ## Send textDocument/didOpen with relPath relative to the langserver/ build root.
  client.notify(
    "textDocument/didOpen",
    %createDidOpenParams(FilePathAbs(absolutePath(relPath)))
  )

proc startServer*(rootRelPath: string): (CommandLineParams, LanguageServer, LspSocketClient) =
  ## Compatibility overload — rootRelPath is ignored here; pass it to doInitialize() separately.
  startServer()

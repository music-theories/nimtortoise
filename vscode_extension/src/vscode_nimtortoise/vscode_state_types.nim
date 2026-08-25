## Types for extension state, this should either get fleshed out or removed
import std/[options, times, tables]
import ../platform/vscodeApi
from ../platform/languageClientApi import VscodeLanguageClient

import api
import forest

type
  Message* = object of JsObject
    message*: cstring
    detail*: cstring
    `type`*: MessageType

type
  LspItem* = ref object of TreeItem
    instance*: Option[NimSuggestStatus]
    notification*: Option[Notification]
    nimbleProjectDir*: DirPathAbs # non-empty on nimble project group items in the tree

  Notification* = object
    message*: cstring
    detail*: cstring  ## optional longer description shown in the modal; falls back to message
    kind*: cstring
    id*: cstring
    date*: DateTime

  NimLangServerStatusProvider* = ref object of JsObject
    status*: Option[NimTortoiseServerStatus]
    notifications*: seq[Notification]
    lastId*: int32 # onDidChangeTreeData*: EventEmitter

  LSPVersion* = tuple[major: int, minor: int, patch: int]

  LSPInstallPathKind* = enum
    lspPathSetting, lspPathLocal, lspPathGlobal, lspPathInvalid

type    
  ExtensionState* = ref object
    ctx*: VscodeExtensionContext
    config*: VscodeWorkspaceConfiguration
    channel*: VscodeOutputChannel
    lspChannel*: VscodeOutputChannel
    client*: VscodeLanguageClient
    statusProvider*: NimLangServerStatusProvider
    lspVersion*: LSPVersion
    lspExtensionCapabilities*: set[LspExtensionCapability]
    nimbleTasks*: seq[NimbleTask]
    propagatedDecorations*: Table[cstring, seq[VscodeTextEditorDecorationType]]
    extensionReady*: bool
    onExtensionReadyHooks*: seq[proc()] # Called when the extension has stablished the connection with the lsp server and is initialized
    
    
    # dumpTestEntryPoint*: cstring #Extracted from nimble dump. 

    # installPerformed*: bool
    # nimDir*: string
      # Nim used directory. Extracted on activation from nimble. When it's "", means nim in the PATH is used.
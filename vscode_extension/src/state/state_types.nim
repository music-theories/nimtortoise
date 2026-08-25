## Types for extension state, this should either get fleshed out or removed
import std/[options, times, strutils, jsconsole, tables]
import platform/vscodeApi

from platform/languageClientApi import VscodeLanguageClient

import api

type
  PendingRequestStatus* = object
    name*: cstring
    projectFile*: cstring
    time*: cstring
    state*: cstring

  NimSuggestStatus* = object
    projectFile*: cstring
    capabilities*: seq[cstring]
    version*: cstring
    protocol*: cstring
    path*: cstring
    port*: int32
    openFiles*: seq[cstring]
    unknownFiles*: seq[cstring]

  ProjectError* = object
    projectFile*: cstring
    errorMessage*: cstring
    lastKnownCmd*: cstring

  NimLangServerStatus* = object
    version*: cstring
    lspPath*: cstring
    nimsuggestInstances*: seq[NimSuggestStatus]
    openFiles*: seq[cstring]
    extensionCapabilities*: seq[cstring]
    pendingRequests*: seq[PendingRequestStatus]
    projectErrors*: seq[ProjectError]

  LspItem* = ref object of TreeItem
    instance*: Option[NimSuggestStatus]
    notification*: Option[Notification]
    nimbleProjectDir*: cstring ## non-empty on nimble project group items in the tree

  Notification* = object
    message*: cstring
    detail*: cstring  ## optional longer description shown in the modal; falls back to message
    kind*: cstring
    id*: cstring
    date*: DateTime

  NimLangServerStatusProvider* = ref object of JsObject
    status*: Option[NimLangServerStatus]
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
    installPerformed*: bool
    nimDir*: string
      # Nim used directory. Extracted on activation from nimble. When it's "", means nim in the PATH is used.
    statusProvider*: NimLangServerStatusProvider
    lspVersion*: LSPVersion
    lspExtensionCapabilities*: set[LspExtensionCapability]
    nimbleTasks*: seq[NimbleTask]
    propagatedDecorations*: Table[cstring, seq[VscodeTextEditorDecorationType]]
    extensionReady*: bool
    onExtensionReadyHooks*: seq[proc()] #Called when the extension has stablished the connection with the lsp server and is initialized
    dumpTestEntryPoint*: cstring #Extracted from nimble dump. 

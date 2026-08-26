import options
import ./primitives
export primitives

type
  DocumentUri = FileUri  # private alias

  # 'off' | 'messages' | 'verbose'
  TraceValue_str = string

  # plain string URI, used for workspace folders
  URI = string

  CancelParams* = ref object of RootObj
    id*: OptionalNode

  Position* = ref object of RootObj
    line*: uinteger
    character*: uinteger

  Range* = ref object of RootObj
    start*: Position
    `end`*: Position

  Location* = ref object of RootObj
    uri*: FileUri
    `range`*: Range

  TextEdit* = ref object of RootObj
    `range`*: Range
    newText*: string

  TextDocumentIdentifier* = ref object of RootObj
    uri*: DocumentUri

  TextDocumentItem* = ref object of RootObj
    uri*: FileUri
    languageId*: string
    version*: int
    text*: string

  VersionedTextDocumentIdentifier* = ref object of TextDocumentIdentifier
    version*: OptionalNode # int 
    languageId*: Option[string]

  TextDocumentPositionParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position

  ExpandTextDocumentPositionParams* = ref object of TextDocumentPositionParams
    level*: Option[int]

  DocumentFilter* = ref object of RootObj
    language*: Option[string]
    scheme*: Option[string]
    pattern*: Option[string]

  MarkupContent* = ref object of RootObj
    kind*: string
    value*: string

  SetTraceParams* = ref object of RootObj
    value*: TraceValue_str

  WorkDoneProgressBegin* = ref object of RootObj
    kind*: string
    title*: string
    cancellable*: Option[bool]
    message*: Option[string]
    percentage*: Option[int]

  WorkDoneProgressReport* = ref object of RootObj
    kind*: string
    cancellable*: Option[bool]
    message*: Option[string]
    percentage*: Option[int]

  WorkDoneProgressEnd* = ref object of RootObj
    kind*: string
    message*: Option[string]

  ProgressParams* = ref object of RootObj
    token*: string # can be also int but the server will send strings
    value*: OptionalNode

  ConfigurationItem* = ref object of RootObj
    scopeUri*: Option[string]
    section*: Option[string]

  ConfigurationParams* = ref object of RootObj
    items*: seq[ConfigurationItem]

  WorkspaceFolder* = ref object of RootObj
    uri*: URI
    name*: string

  StaticRegistrationOptions* = ref object of RootObj
    id*: Option[string]

  TextDocumentRegistrationOptions* = ref object of RootObj
    documentSelector*: OptionalSeq[DocumentFilter]

  TextDocumentAndStaticRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    id*: Option[string]

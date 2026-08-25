import json, options
import ./lsp_diagnostics
export lsp_diagnostics

type
  Command* = ref object of RootObj
    title*: string
    command*: string
    arguments*: OptionalNode

  CodeAction* = ref object of RootObj
    command*: Command
    title*: string
    kind*: string

  TextDocumentEdit* = ref object of RootObj
    textDocument*: VersionedTextDocumentIdentifier
    edits*: OptionalSeq[TextEdit]

  WorkspaceEdit* = ref object of RootObj
    changes*: OptionalNode
    documentChanges*: OptionalSeq[TextDocumentEdit]

  FileRename* = ref object of RootObj
    oldUri*: FileUri
    newUri*: FileUri

  RenameFilesParams* = ref object of RootObj
    files*: seq[FileRename]

  FileDelete* = ref object of RootObj
    uri*: FileUri

  DeleteFilesParams* = ref object of RootObj
    files*: seq[FileDelete]

  WorkspaceFoldersChangeEvent* = ref object of RootObj
    added*: OptionalSeq[WorkspaceFolder]
    removed*: OptionalSeq[WorkspaceFolder]

  DidChangeWorkspaceFoldersParams* = ref object of RootObj
    event*: WorkspaceFoldersChangeEvent

  DidChangeConfigurationParams* = ref object of RootObj
    settings*: OptionalNode

  FileEvent* = ref object of RootObj
    uri*: FileUri
    `type`*: int

  DidChangeWatchedFilesParams* = ref object of RootObj
    changes*: OptionalSeq[FileEvent]

  FileSystemWatcher* = ref object of RootObj
    globPattern*: string
    kind*: Option[int]

  DidChangeWatchedFilesRegistrationOptions* = ref object of RootObj
    watchers*: OptionalSeq[FileSystemWatcher]

  WorkspaceSymbolParams* = ref object of RootObj
    query*: string

  ApplyWorkspaceEditParams* = ref object of RootObj
    label*: Option[string]
    edit*: WorkspaceEdit

  ApplyWorkspaceEditResponse* = ref object of RootObj
    applied*: bool

  DidOpenTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentItem

  TextDocumentContentChangeEvent* = ref object of RootObj
    `range`*: Option[Range]
    rangeLength*: Option[int]
    text*: string

  DidChangeTextDocumentParams* = ref object of RootObj
    textDocument*: VersionedTextDocumentIdentifier
    contentChanges*: seq[TextDocumentContentChangeEvent]

  TextDocumentChangeRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    syncKind*: int

  WillSaveTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    reason*: int

  DidSaveTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    text*: Option[string]

  TextDocumentSaveRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    includeText*: Option[bool]

  DidCloseTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  ShowMessageParams* = ref object of RootObj
    `type`*: int
    message*: string

  MessageActionItem* = ref object of RootObj
    title*: string

  ShowMessageRequestParams* = ref object of RootObj
    `type`*: int
    message*: string
    actions*: OptionalSeq[MessageActionItem]

  LogMessageParams* = ref object of RootObj
    `type`*: int
    message*: string

  CompletionContext* = ref object of RootObj
    triggerKind*: int
    triggerCharacter*: Option[string]

  CompletionParams* = ref object of TextDocumentPositionParams
    context*: Option[CompletionContext]

  CompletionItemLabelDetails* = ref object of RootObj
    detail*: Option[string]
    description*: Option[string]

  CompletionItem* = ref object of RootObj
    label*: string
    kind*: Option[int]
    detail*: Option[string]
    documentation*: OptionalNode #Option[string or MarkupContent]
    deprecated*: Option[bool]
    preselect*: Option[bool]
    sortText*: Option[string]
    filterText*: Option[string]
    insertText*: Option[string]
    insertTextFormat*: Option[int]
    # textEdit*: Option[TextEdit]
    # additionalTextEdits*: Option[TextEdit]
    commitCharacters*: OptionalSeq[string]
    command*: Option[Command]
    data*: OptionalNode
    labelDetails*: Option[CompletionItemLabelDetails]

  CompletionList* = ref object of RootObj
    isIncomplete*: bool
    `items`*: OptionalSeq[CompletionItem]

  CompletionRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    triggerCharacters*: OptionalSeq[string]
    resolveProvider*: Option[bool]

  MarkedStringOption* = ref object of RootObj
    language*: string
    value*: string

  Hover* = ref object of RootObj
    contents*: OptionalNode
      # string or MarkedStringOption or [string] or [MarkedStringOption] or MarkupContent
    `range`*: Option[Range]

  HoverParams* = ref object of TextDocumentPositionParams

  ParameterInformation* = ref object of RootObj
    label*: string # documentation*: Option[string]

  SignatureInformation* = ref object of RootObj
    label*: string
    # documentation*: Option[string]
    parameters*: seq[ParameterInformation]

  SignatureHelp* = ref object of RootObj
    signatures*: OptionalSeq[SignatureInformation]
    activeSignature*: Option[int]
    activeParameter*: Option[int]

  SignatureHelpContext* = ref object of RootObj
    triggerKind*: int
    triggerCharacter*: Option[string]
    isRetrigger*: bool
    activeSignatureHelp*: Option[SignatureHelp]

  SignatureHelpParams* = ref object of TextDocumentPositionParams
    context*: Option[SignatureHelpContext]

  SignatureHelpRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    triggerCharacters*: OptionalSeq[string]

  ReferenceContext* = ref object of RootObj
    includeDeclaration*: bool

  ReferenceParams* = ref object of TextDocumentPositionParams
    context*: ReferenceContext

  DocumentHighlight* = ref object of RootObj
    `range`*: Range
    kind*: Option[int]

  DocumentSymbolParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  SymbolInformation* = ref object of RootObj
    name*: string
    kind*: int
    deprecated*: Option[bool]
    location*: Location
    containerName*: Option[string]

  CodeActionContext* = ref object of RootObj
    diagnostics*: OptionalSeq[Diagnostic]

  CodeActionParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    `range`*: Range
    context*: CodeActionContext

  CodeLensParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  CodeLens* = ref object of RootObj
    `range`*: Range
    command*: Option[Command]
    data*: OptionalNode

  CodeLensRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    resolveProvider*: Option[bool]

  DocumentLinkParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  DocumentLink* = ref object of RootObj
    `range`*: Range
    target*: Option[string]
    data*: OptionalNode

  DocumentLinkRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    resolveProvider*: Option[bool]

  DocumentColorParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  Color* = ref object of RootObj
    red*: int
    green*: int
    blue*: int
    alpha*: int

  ColorInformation* = ref object of RootObj
    `range`*: Range
    color*: Color

  ColorPresentationParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    color*: Color
    `range`*: Range

  ColorPresentation* = ref object of RootObj
    label*: string
    textEdit*: Option[TextEdit]
    additionalTextEdits*: OptionalSeq[TextEdit]

  DocumentFormattingParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    options*: OptionalNode

  DocumentRangeFormattingParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    `range`*: Range
    options*: OptionalNode

  DocumentOnTypeFormattingParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position
    ch*: string
    options*: OptionalNode

  DocumentOnTypeFormattingRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    firstTriggerCharacter*: string
    moreTriggerCharacter*: OptionalSeq[string]

  RenameParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position
    newName*: string

  PrepareRenameParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position

  PrepareRenameResponse* = ref object of RootObj
    defaultBehaviour*: bool

  ExpandResult* = ref object of RootObj
    `range`*: Range
    content*: string

  InlayHintParams* = ref object of RootObj # TODO: extends WorkDoneProgressParams
    textDocument*: TextDocumentIdentifier
    `range`*: Range

  InlayHintKind_int* = int

  InlayHint* = ref object of RootObj
    position*: Position
    label*: string # string | InlayHintLabelPart[]
    kind*: Option[InlayHintKind_int]
    textEdits*: OptionalSeq[TextEdit]
    tooltip*: Option[string] # string | MarkupContent
    paddingLeft*: Option[bool]
    paddingRight*: Option[bool] #data*: OptionalNode

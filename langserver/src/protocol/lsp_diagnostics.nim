import options
import ./lsp_basic
export lsp_basic

type
  Diagnostic* = ref object of RootObj
    `range`*: Range
    severity*: Option[int]
    code*: OptionalNode # int or string
    source*: Option[string]
    message*: string
    relatedInformation*: OptionalSeq[DiagnosticRelatedInformation]

  DiagnosticRelatedInformation* = ref object of RootObj
    location*: Location
    message*: string

  PublishDiagnosticsParams* = ref object of RootObj
    uri*: FileUri
    diagnostics*: OptionalSeq[Diagnostic]

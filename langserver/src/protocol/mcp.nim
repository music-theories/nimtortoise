import json, options
import ./primitives
export primitives

type
  McpListToolsParams* = ref object of RootObj

  McpCallToolParams* = ref object of RootObj
    name*: string
    arguments*: OptionalNode

  McpInitializeParams_clientInfo_Icon_theme* = enum
    light = "light"
    dark = "dark"

  McpInitializeParams_clientInfo_Icon* = ref object of RootObj
    src*: string
    mimeType*: Option[string]
    sizes*: OptionalSeq[string]
    theme*: Option[McpInitializeParams_clientInfo_Icon_theme]

  McpInitializeParams_clientInfo* = ref object of RootObj
    icons*: OptionalSeq[McpInitializeParams_clientInfo_Icon]
    name*: string
    title*: Option[string]
    version*: string
    description*: Option[string]
    websiteUrl*: Option[string]

  McpClientCapabilities* = ref object of RootObj

  McpToolSchema* = object
    `type`*: string
    properties*: JsonNode
    required*: seq[string]

  McpTool* = object
    name*: string
    title*: string
    description*: string
    inputSchema*: McpToolSchema
    outputSchema*: McpToolSchema

  McpListToolsResult* = ref object of RootObj
    tools*: seq[McpTool]

  McpContentBlockType* = enum
    TextContent = "text"

  McpContentBlock* = object
    case `type`*: McpContentBlockType
    of TextContent:
      text*: string

  McpCallToolResult* = ref object of RootObj
    content*: seq[McpContentBlock]
    structuredContent*: JsonNode
    isError*: bool

  McpToolsOptions* = object

  McpServerCapabilities* = ref object of RootObj
    tools*: McpToolsOptions

  McpInitializeParams_serverInfo* = ref object of RootObj
    name*: string
    version*: string

  McpInitializeResult* = ref object of RootObj
    protocolVersion*: string
    capabilities*: McpServerCapabilities
    serverInfo*: McpInitializeParams_serverInfo

  McpInitializeParams* = ref object of RootObj
    protocolVersion*: string
    capabilities*: McpClientCapabilities
    clientInfo*: McpInitializeParams_clientInfo

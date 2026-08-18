import
  std/[
    jsconsole, strutils, jsfetch, asyncjs, sugar, sequtils, options, strformat, times,
    sets,
  ]
import platform/[vscodeApi, languageClientApi]

import
  platform/js/
    [jsNodeFs, jsNodePath, jsNodeCp, jsNodeUtil, jsNodeOs, jsNodeNet, jsPromise]

import ../tools/nimUtils
from ../tools/nimBinTools import getNimbleExecPath, getBinPath
import ../state/state_types
import ../state/state
import ../language_server/language_server

proc getWebviewContent(status: NimLangServerStatus): cstring =
  result = cstring(
    &"""
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nim Language Server Status</title>
    <style>
      body {{
        font-family: Arial, sans-serif;
        padding: 20px;
      }}
      .status {{
        margin-bottom: 20px;
      }}
      .status-item {{
        margin-bottom: 10px;
      }}
      .status-header {{
        font-weight: bold;
        margin-bottom: 5px;
      }}
    </style>
  </head>
  <body>
    <div class="status">
      <div class="status-header">Version: {status.version}</div>
      <div class="status-header">Open Files: {status.openFiles.join(", ")}</div>
      <div class="status-header">Nim Suggest Instances:</div>
      <ul>
       TODO
      </ul>
    </div>
  </body>
  </html>
  """
  )

proc displayStatusInWebview(status: NimLangServerStatus) =
  let panel = vscode.window.createWebviewPanel(
    "nim", "Nim", VscodeViewColumn.one, VscodeWebviewPanelOptions()
  )
  panel.webview.html = getWebviewContent(status)

proc toRelPath(absolutePathOrUri: cstring): cstring =
  ## Returns path relative to the first workspace folder, or the original
  ## value if no workspace is open or the value is not under the workspace root.
  ## Accepts both plain file paths and file:// URIs.
  let fsPath =
    if ($absolutePathOrUri).startsWith("file://"):
      vscode.uriParse(absolutePathOrUri).fsPath
    else:
      absolutePathOrUri
  if vscode.workspace.workspaceFolders.toJs().to(bool) and
      vscode.workspace.workspaceFolders.len > 0:
    let root = vscode.workspace.workspaceFolders[0].uri.fsPath
    let rel = path.relative(root, fsPath)
    if rel.len > 0:
      return rel
  fsPath


proc newLspItem*(
    label: cstring,
    description: cstring = "",
    tooltip: cstring = "",
    collapsibleState: int = 0,
    instance: Option[NimSuggestStatus] = none(NimSuggestStatus),
    iconPath: Option[JsObject] = none(JsObject),
    pendingRequest: Option[PendingRequestStatus] = none(PendingRequestStatus),
    projectError: Option[ProjectError] = none(ProjectError),
    notification: Option[Notification] = none(Notification),
): LspItem =
  let statusItem = vscode.newTreeItem(label, collapsibleState)
  statusItem.description = description
  statusItem.tooltip = tooltip
  statusItem.instance = instance
  statusItem.notification = notification
  statusItem.pendingRequest = pendingRequest
  statusItem.projectError = projectError
  statusItem.nimbleProjectDir = ""
  if projectError.isSome():
    let pe = projectError.get()
    outputLine(fmt"Error executing command: \n {pe.lastKnownCmd}".cstring)
    outputLine(fmt"In project: \n{pe.projectFile}".cstring)
    outputLine(fmt"StackTrace (if none appears compile nimsuggest with --lineTrace) \n {pe.errorMessage}".cstring)
  if iconPath.isSome:
    statusItem.iconPath = iconPath.get
  cast[LspItem](statusItem)

proc onLspSuggest*(action, projectFile: cstring) {.async.} =
  #Handles extension/suggest calls 
  #(right now only from the restart button in the suggest instance from the nim panel)
  var projectFile = projectFile
  if projectFile == "current":
    var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
    console.log("llega")
    if activeEditor.isNil():
      return
    projectFile = activeEditor.document.fileName
    console.log(projectFile)

  case action
  of "restart", "restartAll":
    outputLine((&"Path to file {projectFile}").cstring)
    let suggestParams = JsObject()
    suggestParams.action = action
    suggestParams.projectFile = projectFile
    let response =
      await fetchLsp[JsObject, JsObject](ext, "extension/suggest", suggestParams)
    console.log(response)
  else:
    console.error("Action not supported")

proc onCheckProject*() {.async.} =
  var activeEditor: VscodeTextEditor = vscode.window.activeTextEditor
  if activeEditor.isNil():
    return
  let projectFile = activeEditor.document.fileName
  let params = newJsObject()
  params.command = "nimtortoise.checkProject".cstring
  params.arguments = @[projectFile.toJs()]
  discard await ext.client.sendRequest("workspace/executeCommand", params)

proc onShowNotification*(args: JsObject) =
  let message = args.to(cstring)
  vscode.window.showInformationMessage(
    "Details", VscodeMessageOptions(detail: message, modal: true)
  )

proc onDeleteNotification*(args: JsObject) =
  let id = args.to(cstring)
  let state = nimUtils.ext
  let notifications = state.statusProvider.notifications.filterIt(it.id != id)
  refreshNotifications(state.statusProvider, notifications)

proc onClearAllNotifications*() =
  refreshNotifications(nimUtils.ext.statusProvider, @[])

proc newNotificationItem*(notification: Notification): LspItem =
  let item = vscode.newTreeItem("Notification", TreeItemCollapsibleState_Collapsed)
  item.label = notification.message
  item.notification = some(notification)
  # item.context.isNotification = true
  item.command = newJsObject()
  item.command.command = "nimTortoise.showNotification".cstring
  item.command.title = "Show Notification".cstring
  item.command.arguments = @[notification.message.toJs()]
  item.tooltip = notification.message
  let color =
    fmt"notifications{capitalizeAscii($notification.kind)}Icon.foreground".cstring
  item.iconPath = vscode.themeIcon(notification.kind, vscode.themeColor(color))
  cast[LspItem](item)

proc isNotificationItem(item: LspItem): bool =
  not item.notification.isUndefined and item.notification.isSome

proc notificationActionItems(lspItem: LspItem): seq[LspItem] =
  #Returns a child with the detail clickable and a child for deleting it
  let notification = lspItem.notification.get()
  let item = vscode.newTreeItem("Details", TreeItemCollapsibleState_None)
  # item.title = "Details"
  item.command = newJsObject()
  item.command.command = "nimTortoise.showNotification".cstring
  item.command.title = "Show Notification".cstring
  item.command.arguments = @[notification.message.toJs()]
  item.iconPath =
    vscode.themeIcon("selection", vscode.themeColor("notificationsInfoIcon.foreground"))
  result.add cast[LspItem](item)

  let item2 = vscode.newTreeItem("Delete", TreeItemCollapsibleState_None)
  # item2.title = "Delete"
  item2.command = newJsObject()
  item2.command.command = "nimTortoise.onDeleteNotification".cstring
  item2.command.title = "Delete Notification".cstring
  item2.iconPath =
    vscode.themeIcon("trash", vscode.themeColor("notificationsErrorIcon.foreground"))
  item2.command.arguments = @[notification.id.toJs()]
  result.add cast[LspItem](item2)

proc globalNotificationActionItems(): seq[LspItem] =
  if nimUtils.ext.statusProvider.notifications.len == 0:
    return @[]
  let item = vscode.newTreeItem("Clear All", TreeItemCollapsibleState_None)
  item.command = newJsObject()
  item.command.command = "nimTortoise.onClearAllNotifications".cstring
  item.command.title = "Clear All Notifications".cstring
  item.iconPath =
    vscode.themeIcon("trash", vscode.themeColor("notificationsErrorIcon.foreground"))
  @[cast[LspItem](item)]

proc onNimbleTask*(name: cstring, projectDir: cstring = "") {.async.} =
  let task = ext.getTaskByName(name, projectDir)
  if task.isNone or task.get.isRunning:
    console.log("Task already running or not found")
    return
  console.log("Executing onNimbleTask", name, projectDir)
  let taskParams = RunTaskParams(command: @[name], workingDir: projectDir)

  vscode.window
  .withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.notification,
      cancellable: false,
      title: cstring(fmt"Nim: running task '{name}'..."),
    },
    proc(): Promise[RunTaskResult] =
      ext.markTaskAsRunning(name, projectDir, true)
      fetchLsp[RunTaskResult, RunTaskParams](ext, "extension/runTask", taskParams),
  )
  .then(
    proc(taskResult: RunTaskResult) =
      ext.markTaskAsRunning(name, projectDir, false)
      outputLine(fmt"Task {name} finished".cstring)
      for line in taskResult.output:
        outputLine(line)
      
      let panel = vscode.window.createWebviewPanel(
        "nimTask",
        cstring(fmt"Nim Task: {name}"),
        VscodeViewColumn.one,
        VscodeWebviewPanelOptions()
      )
      
      panel.webview.html = cstring(&"""
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <style>
            body {{ 
              padding: 10px;
              font-family: var(--vscode-editor-font-family);
              font-size: var(--vscode-editor-font-size);
            }}
            pre {{
              background-color: var(--vscode-editor-background);
              padding: 10px;
              border-radius: 4px;
              overflow-x: auto;
            }}
          </style>
        </head>
        <body>
          <h2>Task: {name}</h2>
          <h3>Command:</h3>
          <pre>{taskResult.command.join(" ")}</pre>
          <h3>Output:</h3>
          <pre>{taskResult.output.join("\n")}</pre>
        </body>
        </html>
      """)
      
  )
  .catch(
    proc(reason: JsObject) =
      console.error("nimvscode - onNimbleTask Failed", reason)
  )

proc newNimbleProjectItem*(projectDir: cstring): LspItem =
  let label = ($projectDir).split("/")[^1].cstring
  let item = newLspItem(label, "", "", TreeItemCollapsibleState_Collapsed)
  item.iconPath = vscode.themeIcon("folder", vscode.themeColor("terminal.ansiCyan"))
  item.nimbleProjectDir = projectDir
  item

proc newNimbleTaskItem*(task: NimbleTask): LspItem =
  let item = vscode.newTreeItem(task.name, TreeItemCollapsibleState_None)
  item.description = task.description
  item.command = newJsObject()
  item.command.command = "nimTortoise.onNimbleTask".cstring
  item.command.title = task.name.cstring
  item.command.arguments = @[task.name.toJs(), task.projectDir.toJs()]
  # item.iconPath = vscode.themeIcon("debug-start", vscode.themeColor("notificationsInfoIcon.foreground"))
  
  # Set different icon based on running state
  if task.isRunning:
    item.iconPath = vscode.themeIcon(
      "sync~spin", # This is VSCode's built-in spinning icon
      vscode.themeColor("activityBarBadge.background")
    )
  else:
    item.iconPath = vscode.themeIcon(
      "play-circle",
      vscode.themeColor("terminal.ansiGreen")
    )
    
  cast[LspItem](item)

proc newRefreshNimbleTasksItem*(): LspItem =
  let item = vscode.newTreeItem("Get Nimble Tasks", TreeItemCollapsibleState_None)
  item.command = newJsObject()
  item.command.command = "nimTortoise.onRefreshNimbleTasks".cstring
  item.command.title = "Get Nimble Tasks".cstring
  item.iconPath = vscode.themeIcon("refresh", vscode.themeColor("notificationsInfoIcon.foreground"))
  cast[LspItem](item)


#[
  - Root
    - Notifications
    - LSP Status

]#
proc newRestartItem(title: string, pathToFile: string, action: static string): LspItem =
  # patth to file * == restart all
  let restartItem = vscode.newTreeItem(title, TreeItemCollapsibleState_None)
  restartItem.command = newJsObject()
  restartItem.command.command = "nimTortoise.onLspSuggest".cstring
  restartItem.command.title = title.cstring
  #Notice the actions here corresponds to SuggestAction in the lsp rathen than capabilities
  restartItem.command.arguments = @[cstring(action), pathToFile.cstring]
  restartItem.iconPath = vscode.themeIcon(
    "debug-restart", vscode.themeColor("notificationsWarningIcon.foreground")
  )
  cast[LspItem](restartItem)

proc newCheckProjectItem(): LspItem =
  let item = vscode.newTreeItem("Check Project", TreeItemCollapsibleState_None)
  item.tooltip = "Restart nimsuggest and run a full compile check for the active file's project"
  item.iconPath = vscode.themeIcon("refresh", vscode.themeColor("terminal.ansiGreen"))
  item.command = newJsObject()
  item.command.command = "nimTortoise.checkProject".cstring
  item.command.title = "Check Project".cstring
  cast[LspItem](item)

proc getChildrenImpl(
    self: NimLangServerStatusProvider, element: LspItem = nil
): seq[LspItem] =
  # --- Root ---
  if element.isNil:
    let pendingCount =
      if self.status.isSome: self.status.get.pendingRequests.len else: 0
    let pendingDesc = if pendingCount > 0: cstring($pendingCount) else: "".cstring
    var rootItems = @[
      newLspItem("LSP Status", "", "", TreeItemCollapsibleState_Collapsed),
      newLspItem("Pending Requests", pendingDesc, "", TreeItemCollapsibleState_Collapsed),
      newLspItem("Nimsuggest Pool", "", "", TreeItemCollapsibleState_Expanded),
    ]
    if excNimbleTask in ext.lspExtensionCapabilities:
      rootItems.add(newLspItem("Nimble Tasks", "", "", TreeItemCollapsibleState_Expanded))
    rootItems.add(newLspItem("LSP Notifications", "", "", TreeItemCollapsibleState_Expanded))
    return rootItems

  # --- Notifications (no status needed) ---
  elif element.label == "LSP Notifications":
    return globalNotificationActionItems() &
      self.notifications.mapIt(newNotificationItem(it))
  elif element.isNotificationItem:
    return notificationActionItems(element)

  # --- Nimble Tasks (no status needed) ---
  elif element.label == "Nimble Tasks":
    var seen: seq[cstring]
    var groupItems: seq[LspItem] = @[newRefreshNimbleTasksItem()]
    for task in ext.nimbleTasks:
      if task.projectDir notin seen:
        seen.add(task.projectDir)
        groupItems.add(newNimbleProjectItem(task.projectDir))
    return groupItems
  elif cast[LspItem](element).nimbleProjectDir != "":
    let dir = cast[LspItem](element).nimbleProjectDir
    return ext.nimbleTasks.filterIt(it.projectDir == dir).mapIt(newNimbleTaskItem(it))

  # --- Everything else requires status ---
  else:
    if self.status.isNone:
      return @[newLspItem("Waiting for nimlangserver to init", "", "", TreeItemCollapsibleState_None)]

    let status = self.status.get

    if element.label == "LSP Status":
      return @[
        newLspItem("Langserver", status.lspPath),
        newLspItem("Version", status.version),
      ]

    elif element.label == "Pending Requests":
      let reqs = status.pendingRequests
      if reqs.len == 0:
        return @[newLspItem("None", "", "", TreeItemCollapsibleState_None)]
      return reqs.mapIt(
        newLspItem(it.name, "", "", TreeItemCollapsibleState_Expanded, pendingRequest = some it)
      )
    elif element.pendingRequest.to(Option[PendingRequestStatus]).isSome:
      let pr = element.pendingRequest.to(Option[PendingRequestStatus]).get()
      let timeTitle = if pr.state == "OnGoing": "Waiting for" else: "Took"
      var prItems = @[
        newLspItem(timeTitle.cstring, pr.time, "", TreeItemCollapsibleState_None),
        newLspItem("State", pr.state.cstring, "", TreeItemCollapsibleState_None),
      ]
      if pr.projectFile != "":
        prItems.add(newLspItem("NimSuggest", pr.projectFile, "", TreeItemCollapsibleState_None))
      return prItems

    elif element.label == "Nimsuggest Pool":
      var items: seq[LspItem]
      if excRestartSuggest in ext.lspExtensionCapabilities:
        items.add(newRestartItem("Restart All Nimsuggest", "", "restartAll"))
      items &= status.nimsuggestInstances.mapIt(
        newLspItem(toRelPath(it.projectFile), "", "", TreeItemCollapsibleState_Collapsed, some it)
      )
      return items

    elif element.label == "Open Files" and element.instance.isSome:
      let files = element.instance.get.openFiles
      if files.len == 0:
        return @[newLspItem("None", "", "", TreeItemCollapsibleState_None)]
      return files.mapIt(newLspItem(toRelPath(it), "", "", TreeItemCollapsibleState_None))

    elif ($element.label).startsWith("Project Errors") and element.instance.isSome:
      let projectFile = element.instance.get.projectFile
      let errors = status.projectErrors.filterIt(it.projectFile == projectFile)
      if errors.len == 0:
        return @[newLspItem("None", "", "", TreeItemCollapsibleState_None)]
      return errors.mapIt(
        newLspItem(toRelPath(it.projectFile), "", "", TreeItemCollapsibleState_Expanded, projectError = some it)
      )
    elif element.projectError.to(Option[ProjectError]).isSome:
      let pe = element.projectError.to(Option[ProjectError]).get()
      return @[
        newLspItem("Error:", pe.errorMessage, "", TreeItemCollapsibleState_None),
        newLspItem("Last Known Cmd:", pe.lastKnownCmd, "", TreeItemCollapsibleState_None),
      ]

    elif element.instance.isSome:
      # Per-instance children
      let instance = element.instance.get
      let errorCount = status.projectErrors.filterIt(it.projectFile == instance.projectFile).len
      let errorLabel =
        if errorCount > 0: cstring(&"Project Errors ({errorCount})")
        else: "Project Errors".cstring
      var nsItems = @[
        newCheckProjectItem(),
        newLspItem("Capabilities", instance.capabilities.join(", ").cstring),
        newLspItem("Version", instance.version),
        newLspItem("Path", instance.path),
        newLspItem("Port", cstring($instance.port)),
        newLspItem("Open Files", "", "", TreeItemCollapsibleState_Collapsed, instance = element.instance),
        newLspItem(errorLabel, "", "", TreeItemCollapsibleState_Collapsed, instance = element.instance),
      ]
      if excRestartSuggest in ext.lspExtensionCapabilities:
        nsItems.insert(newRestartItem("Restart", $instance.projectFile, "restart"), 1)
      return nsItems

    return @[]

proc getTreeItemImpl(
    self: NimLangServerStatusProvider, element: TreeItem
): Future[TreeItem] {.async.} =
  return element

proc newNimLangServerStatusProvider*(): NimLangServerStatusProvider =
  let provider = cast[NimLangServerStatusProvider](newJsObject())
  let emitter = vscode.newEventEmitter()
  provider.emitter = emitter
  provider.onDidChangeTreeData = emitter.event
  provider.status = none(NimLangServerStatus)
  provider.notifications = @[]
  provider.lastId = 1
  provider.getTreeItem = proc(element: TreeItem): Future[TreeItem] =
    getTreeItemImpl(provider, element)
  provider.getChildren = proc(element: LspItem): seq[LspItem] =
    getChildrenImpl(provider, element)
  provider

proc fetchLspStatus*(state: ExtensionState): Future[NimLangServerStatus] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/status", ().toJs())
  let lspStatus = jsonStringify(response).jsonParse(NimLangServerStatus)
  state.channel.appendLine(($lspStatus).cstring)
  return lspStatus

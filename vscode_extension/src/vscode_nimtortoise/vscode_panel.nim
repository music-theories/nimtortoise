import std/[
  strutils, asyncjs, sequtils, options, strformat
]

import api
import forest

import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[jsNodePath, jsPromise]
import ./[vscode_state_types, vscode_state_utils, vscode_panel_utils]

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
  state: ExtensionState,
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
    outputLine(state, fmt"Error executing command: \n {pe.lastKnownCmd}".cstring)
    outputLine(state, fmt"In project: \n{pe.entryPoint}".cstring)
    outputLine(state, fmt"StackTrace (if none appears compile nimsuggest with --lineTrace) \n {pe.errorMessage}".cstring)
  if iconPath.isSome:
    statusItem.iconPath = iconPath.get
  cast[LspItem](statusItem)

proc newNimbleProjectItem*(
  state: ExtensionState, projectDir: DirPathAbs
): LspItem =
  let label = ($projectDir).split("/")[^1]
  let item = newLspItem(state, label, "", "", TreeItemCollapsibleState_Collapsed)
  item.iconPath = vscode.themeIcon("folder", vscode.themeColor("terminal.ansiCyan"))
  item.nimbleProjectDir = cstring($(projectDir))
  return item

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

proc newPerformanceItem(): LspItem =
  let current = vscode.workspace.getConfiguration("nimTortoise").getStr("performance")
  let item = vscode.newTreeItem("Performance", TreeItemCollapsibleState_None)
  item.description = current
  item.tooltip = "Click to change the performance setting".cstring
  item.iconPath = vscode.themeIcon("settings-gear", vscode.themeColor("notificationsInfoIcon.foreground"))
  item.command = newJsObject()
  item.command.command = "nimTortoise.setPerformance".cstring
  item.command.title = "Set Performance".cstring
  cast[LspItem](item)

proc newCheckProjectItem(): LspItem =
  let item = vscode.newTreeItem("Check Project", TreeItemCollapsibleState_None)
  item.tooltip = "Restart nimsuggest and run a full compile check for the active file's project"
  item.iconPath = vscode.themeIcon("refresh", vscode.themeColor("terminal.ansiGreen"))
  item.command = newJsObject()
  item.command.command = "nimTortoise.checkProject".cstring
  item.command.title = "Check Project".cstring
  cast[LspItem](item)

proc globalNotificationActionItems(
  state: ExtensionState
): seq[LspItem] =
  if state.statusProvider.notifications.len == 0:
    return @[]
  let item = vscode.newTreeItem("Clear All", TreeItemCollapsibleState_None)
  item.command = newJsObject()
  item.command.command = "nimTortoise.onClearAllNotifications".cstring
  item.command.title = "Clear All Notifications".cstring
  item.iconPath =
    vscode.themeIcon("trash", vscode.themeColor("notificationsErrorIcon.foreground"))
  @[cast[LspItem](item)]

proc newNotificationItem*(notification: Notification): LspItem =
  let item = vscode.newTreeItem("Notification", TreeItemCollapsibleState_Collapsed)
  item.label = notification.message
  item.notification = some(notification)
  # item.context.isNotification = true
  item.command = newJsObject()
  item.command.command = "nimTortoise.showNotification".cstring
  item.command.title = "Show Notification".cstring
  item.command.arguments = @[notification.message.toJs(), notification.detail.toJs()]
  item.tooltip = if notification.detail != "".cstring: notification.detail else: notification.message
  let color =
    fmt"notifications{capitalizeAscii($notification.kind)}Icon.foreground".cstring
  item.iconPath = vscode.themeIcon(notification.kind, vscode.themeColor(color))
  cast[LspItem](item)


proc isNotificationItem(item: LspItem): bool =
  not item.notification.isUndefined and item.notification.isSome

proc notificationActionItems(lspItem: LspItem): seq[LspItem] =
  #Returns a child with the detail clickable and a child for deleting it
  let notification: Notification = lspItem.notification.get()
  let item = vscode.newTreeItem("Details", TreeItemCollapsibleState_None)
  # item.title = "Details"
  item.command = newJsObject()
  item.command.command = "nimTortoise.showNotification".cstring
  item.command.title = "Show Notification".cstring
  item.command.arguments = @[notification.message.toJs(), notification.detail.toJs()]
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



proc getChildrenImpl(
  state: ExtensionState, element: LspItem = nil
): seq[LspItem] =
  # --- Root ---
  let self = state.statusProvider

  if element.isNil:
    var pendingCount = 0
    if self.status.isSome(): 
      let serverStatus: NimTortoiseServerStatus = self.status.get()
      pendingCount = serverStatus.pendingRequests.len 

    let pendingDesc = if pendingCount > 0: cstring($pendingCount) else: "".cstring
    var rootItems = @[
      newPerformanceItem(),
      newLspItem(state, "LSP Status", "", "", TreeItemCollapsibleState_Collapsed),
      newLspItem(state, "Pending Requests", pendingDesc, "", TreeItemCollapsibleState_Collapsed),
      newLspItem(state, "Nimsuggest Pool", "", "", TreeItemCollapsibleState_Expanded),
    ]
    if NIMBLE_RUN_TASK in state.lspExtensionCapabilities:
      rootItems.add(newLspItem(state, "Nimble Tasks", "", "", TreeItemCollapsibleState_Expanded))
    rootItems.add(newLspItem(state, "LSP Notifications", "", "", TreeItemCollapsibleState_Expanded))
    return rootItems

  # --- Notifications (no status needed) ---
  elif element.label == "LSP Notifications":
    return globalNotificationActionItems(state) &
      self.notifications.mapIt(newNotificationItem(it))
  elif element.isNotificationItem:
    return notificationActionItems(element)

  # --- Nimble Tasks (no status needed) ---
  elif element.label == "Nimble Tasks":
    var seen: seq[DirPathAbs]
    var groupItems: seq[LspItem] = @[newRefreshNimbleTasksItem()]
    for task in state.nimbleTasks:
      if task.projectDir notin seen:
        seen.add(task.projectDir)
        groupItems.add(
          newNimbleProjectItem(state, task.projectDir)
        )
    return groupItems
  elif cast[LspItem](element).nimbleProjectDir != "":
    let dir = element.nimbleProjectDir
    return state.nimbleTasks.filterIt($(it.projectDir) == dir).mapIt(newNimbleTaskItem(it))

  # --- Everything else requires status ---
  else:
    if self.status.isNone:
      return @[newLspItem(state, "Waiting for nimlangserver to init", "", "", TreeItemCollapsibleState_None)]

    let status = self.status.get()

    if element.label == "LSP Status":
      return @[
        newLspItem(state, "Langserver", cstring($(status.exe.path))),
        newLspItem(state, "Version", cstring($(status.exe.version))),
      ]

    elif element.label == "Pending Requests":
      let reqs = status.pendingRequests
      if reqs.len == 0:
        return @[newLspItem(state, "None", "", "", TreeItemCollapsibleState_None)]
      return reqs.mapIt(
        newLspItem(state, it.name, "", "", TreeItemCollapsibleState_Expanded, pendingRequest = some it)
      )
    elif element.pendingRequest.to(Option[PendingRequestStatus]).isSome:
      let pr = element.pendingRequest.to(Option[PendingRequestStatus]).get()
      let timeTitle = if pr.state == "OnGoing": "Waiting for" else: "Took"
      var prItems = @[
        newLspItem(state, timeTitle.cstring, pr.time, "", TreeItemCollapsibleState_None),
        newLspItem(state, "State", pr.state.cstring, "", TreeItemCollapsibleState_None),
      ]
      if pr.entryPoint != FilePathAbs(""):
        prItems.add(newLspItem(state, "NimSuggest", toRelPath($(pr.entryPoint)), "", TreeItemCollapsibleState_None))
      return prItems

    elif element.label == "Nimsuggest Pool":
      var items: seq[LspItem]
      if NIMSUGGEST_RESTART in state.lspExtensionCapabilities:
        items.add(newRestartItem("Restart Server", "", "serverRestart"))
      items &= status.pool.mapIt(
        newLspItem(
          state, toRelPath($(it.entryPoint)), "", "", TreeItemCollapsibleState_Collapsed, some(it)
        )
      )
      return items

    elif element.label == "Open Files" and element.instance.isSome:
      let files = element.instance.get.openFiles
      if files.len == 0:
        return @[newLspItem(state, "None", "", "", TreeItemCollapsibleState_None)]
      return files.mapIt(newLspItem(state, toRelPath(it), "", "", TreeItemCollapsibleState_None))

    elif ($element.label).startsWith("Project Errors") and element.instance.isSome:
      let entryPoint = element.instance.get().entryPoint
      let errors = status.projectErrors.filterIt(it.entryPoint == entryPoint)
      if errors.len == 0:
        return @[newLspItem(state, "None", "", "", TreeItemCollapsibleState_None)]
      return errors.mapIt(
        newLspItem(state, toRelPath($(it.entryPoint)), "", "", TreeItemCollapsibleState_Expanded, projectError = some it)
      )
    elif element.projectError.to(Option[ProjectError]).isSome:
      let pe = element.projectError.to(Option[ProjectError]).get()
      return @[
        newLspItem(state, "Error:", pe.errorMessage, "", TreeItemCollapsibleState_None),
        newLspItem(state, "Last Known Cmd:", pe.lastKnownCmd, "", TreeItemCollapsibleState_None),
      ]

    elif element.instance.isSome:
      # Per-instance children
      let instance = element.instance.get
      let errorCount = status.projectErrors.filterIt(it.entryPoint == instance.entryPoint).len
      let errorLabel =
        if errorCount > 0: cstring(&"Project Errors ({errorCount})")
        else: "Project Errors".cstring
      var nsItems = @[
        newCheckProjectItem(),
        newLspItem(state, "Version", cstring($instance.version)),
        newLspItem(state, "Protocol", cstring($instance.protocol)),
        newLspItem(state, "Path", instance.path),
        newLspItem(state, "Port", cstring($instance.port)),
        newLspItem(state, "Open Files", "", "", TreeItemCollapsibleState_Collapsed, instance = element.instance),
        newLspItem(state, errorLabel, "", "", TreeItemCollapsibleState_Collapsed, instance = element.instance),
      ]
      if NIMSUGGEST_RESTART in state.lspExtensionCapabilities:
        nsItems.insert(newRestartItem("Restart", $(instance.entryPoint), "restart"), 1)
      return nsItems

    return @[]

proc getTreeItemImpl(
  self: NimLangServerStatusProvider, element: TreeItem
): Future[TreeItem] {.async.} =
  return element

proc initNimLangServerStatusProvider*(state: ExtensionState): NimLangServerStatusProvider =
  let provider = cast[NimLangServerStatusProvider](newJsObject())
  let emitter = vscode.newEventEmitter()
  provider.emitter = emitter
  provider.onDidChangeTreeData = emitter.event
  provider.status = none(NimTortoiseServerStatus)
  provider.notifications = @[]
  provider.lastId = 1
  provider.getTreeItem = proc(element: TreeItem): Future[TreeItem] =
    getTreeItemImpl(provider, element)
  provider.getChildren = proc(element: LspItem): seq[LspItem] =
    getChildrenImpl(state, element)
  provider


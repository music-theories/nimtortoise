import std/[
  strutils, asyncjs, sequtils, options, strformat
]

import api
import resources/resources

import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[jsNodePath, jsPromise]
import ./[vscode_state_types, vscode_state_utils]

proc toRelPath*(absolutePathOrUri: string): string =
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
      return $(rel)
  return $(fsPath)

proc newLspItem*(
  state: ExtensionState,
  label: string,
  description: string = "",
  tooltip: string = "",
  collapsibleState: int = 0,
  instance: Option[NimsuggestStatus] = none(NimsuggestStatus),
  iconPath: Option[JsObject] = none(JsObject),
  pendingRequest: Option[PendingRequestStatus] = none(PendingRequestStatus),
  projectError: Option[ProjectError] = none(ProjectError),
  notification: Option[Notification] = none(Notification),
): LspItem =
  let statusItem = cast[LspItem](vscode.newTreeItem(cstring(label), collapsibleState))
  statusItem.description = cstring(description)
  statusItem.tooltip = cstring(tooltip)
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
  return statusItem

proc newNimbleProjectItem*(
  state: ExtensionState, projectDir: cstring
): LspItem =
  let label = ($projectDir).split("/")[^1]
  let item = newLspItem(state, label, "", "", TreeItemCollapsibleState_Collapsed)
  item.iconPath = vscode.themeIcon("folder", vscode.themeColor("terminal.ansiCyan"))
  item.nimbleProjectDir = $(projectDir)
  return item

proc newNimbleTaskItem*(task: NimbleTask): LspItem =
  let item = cast[LspItem](vscode.newTreeItem(task.name, TreeItemCollapsibleState_None))
  item.description = task.description
  item.command = newJsObject()
  item.command.command = "nimTortoise.nimbleRunTask".cstring
  item.command.title = task.name
  item.command.arguments = @[task.name.toJs(), task.projectDir.toJs()]

  if task.isRunning:
    item.iconPath = vscode.themeIcon(
      "sync~spin",
      vscode.themeColor("activityBarBadge.background")
    )
  else:
    item.iconPath = vscode.themeIcon(
      "play-circle",
      vscode.themeColor("terminal.ansiGreen")
    )
  return item

proc newRefreshNimbleTasksItem*(): LspItem =
  let item = cast[LspItem](vscode.newTreeItem("Get Nimble Tasks", TreeItemCollapsibleState_None))
  item.command = newJsObject()
  item.command.command = "nimTortoise.nimbleListTasks".cstring
  item.command.title = "Get Nimble Tasks".cstring
  item.iconPath = vscode.themeIcon("refresh", vscode.themeColor("notificationsInfoIcon.foreground"))
  return item

# === SERVER ITEMS

proc newServerRestartItem*(): LspItem =
  let item = cast[LspItem](vscode.newTreeItem("Restart", TreeItemCollapsibleState_None))
  item.tooltip = "Restart the language server"
  item.iconPath = vscode.themeIcon("debug-restart", vscode.themeColor("notificationsWarningIcon.foreground"))
  item.command = newJsObject()
  item.command.command = "nimTortoise.serverRestart".cstring
  item.command.title = "Restart Language Server".cstring
  return item

proc newPerformanceItem*(): LspItem =
  let current = vscode.workspace.getConfiguration("nimTortoise").getStr("performance")
  let item = cast[LspItem](vscode.newTreeItem("Performance", TreeItemCollapsibleState_None))
  item.description = current
  item.tooltip = "Click to change the performance setting".cstring
  item.iconPath = vscode.themeIcon("settings-gear", vscode.themeColor("notificationsInfoIcon.foreground"))
  item.command = newJsObject()
  item.command.command = "nimTortoise.setPerformance".cstring
  item.command.title = "Set Performance".cstring
  return item

# === NIMSUGGEST ITEMS ===

proc newCheckProjectItem*(entryPoint: string): LspItem =
  let item = cast[LspItem](vscode.newTreeItem("Check Project", TreeItemCollapsibleState_None))
  item.tooltip = "Restart nimsuggest and run a full compile check for the active file's project"
  item.iconPath = vscode.themeIcon("refresh", vscode.themeColor("terminal.ansiGreen"))
  item.command = newJsObject()
  item.command.command = "nimTortoise.nimsuggestCheckProject".cstring
  item.command.title = "Check Project".cstring
  item.command.arguments = @[entryPoint.cstring.toJs()]
  return item

proc newNimsuggestStopItem*(entryPoint: string): LspItem =
  let item = cast[LspItem](vscode.newTreeItem("Stop", TreeItemCollapsibleState_None))
  item.tooltip = "Stop this nimsuggest instance"
  item.iconPath = vscode.themeIcon("debug-stop", vscode.themeColor("notificationsErrorIcon.foreground"))
  item.command = newJsObject()
  item.command.command = "nimTortoise.nimsuggestStop".cstring
  item.command.title = "Stop Nimsuggest".cstring
  item.command.arguments = @[entryPoint.cstring.toJs()]
  return item

# === NOTIFICATION ITEMS ===

proc globalNotificationActionItems*(
  state: ExtensionState
): seq[LspItem] =
  if state.statusProvider.notifications.len == 0:
    return @[]
  let item = cast[LspItem](vscode.newTreeItem("Clear All", TreeItemCollapsibleState_None))
  item.command = newJsObject()
  item.command.command = "nimTortoise.onClearAllNotifications".cstring
  item.command.title = "Clear All Notifications".cstring
  item.iconPath =
    vscode.themeIcon("trash", vscode.themeColor("notificationsErrorIcon.foreground"))
  @[item]

proc newNotificationItem*(notification: Notification): LspItem =
  let item = cast[LspItem](vscode.newTreeItem("Notification", TreeItemCollapsibleState_Collapsed))
  item.label = notification.message
  item.notification = some(notification)
  item.command = newJsObject()
  item.command.command = "nimTortoise.showNotification".cstring
  item.command.title = "Show Notification".cstring
  item.command.arguments = @[notification.message.toJs(), notification.detail.toJs()]
  item.tooltip = if notification.detail != "".cstring: notification.detail else: notification.message
  let color =
    fmt"notifications{capitalizeAscii($notification.kind)}Icon.foreground".cstring
  item.iconPath = vscode.themeIcon(notification.kind, vscode.themeColor(color))
  return item

proc isNotificationItem*(item: LspItem): bool =
  not item.notification.isUndefined and item.notification.isSome

proc notificationActionItems*(lspItem: LspItem): seq[LspItem] =
  #Returns a child with the detail clickable and a child for deleting it
  let notification: Notification = lspItem.notification.get()
  let item = cast[LspItem](vscode.newTreeItem("Details", TreeItemCollapsibleState_None))
  item.command = newJsObject()
  item.command.command = "nimTortoise.showNotification".cstring
  item.command.title = "Show Notification".cstring
  item.command.arguments = @[notification.message.toJs(), notification.detail.toJs()]
  item.iconPath =
    vscode.themeIcon("selection", vscode.themeColor("notificationsInfoIcon.foreground"))
  result.add(item)

  let item2 = cast[LspItem](vscode.newTreeItem("Delete", TreeItemCollapsibleState_None))
  item2.command = newJsObject()
  item2.command.command = "nimTortoise.onDeleteNotification".cstring
  item2.command.title = "Delete Notification".cstring
  item2.iconPath =
    vscode.themeIcon("trash", vscode.themeColor("notificationsErrorIcon.foreground"))
  item2.command.arguments = @[notification.id.toJs()]
  result.add(item2)

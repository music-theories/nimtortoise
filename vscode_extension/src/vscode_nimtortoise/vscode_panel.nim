import std/[
  strutils, asyncjs, sequtils, options, strformat, times
]

import api
import resources/resources

import ../platform/[vscodeApi, languageClientApi]
import ../platform/js/[jsNodePath, jsPromise]
import ./[vscode_state_types, vscode_state_utils]
import ./[vscode_panel_items]

proc initRootItems(
  state: ExtensionState, element: LspItem
): seq[LspItem] =
  # --- Root ---
  let self = state.statusProvider

  var pendingCount = ""
  var slotCount = ""
  var errorCount = ""
  var openFileCount = ""
  
  if self.status.isSome():
    let serverStatus: NimTortoiseServerStatus = self.status.get()

    if serverStatus.pendingRequests.len == 0:
      pendingCount = ""
    else:
      pendingCount = $(serverStatus.pendingRequests.len)

    if serverStatus.pool.len == 0:
      slotCount = ""
    else:
      slotCount = $(serverStatus.pool.len)
    
    if serverStatus.projectErrors.len == 0:
      errorCount = ""
    else:
      errorCount = $(serverStatus.projectErrors.len)

    if serverStatus.openFiles.len == 0:
      openFileCount = ""
    else:
      openFileCount = $(serverStatus.openFiles.len)
  
  var rootItems = @[
    newPerformanceItem(),
    newLspItem(state, "LSP Status", "", "", TreeItemCollapsibleState_Collapsed),
    newLspItem(state, "Pending Requests", pendingCount, "", TreeItemCollapsibleState_Collapsed),
    newLspItem(state, "Project Errors", errorCount, "", TreeItemCollapsibleState_Expanded),
    newLspItem(
      state, "Open Files", openFileCount, 
      "", TreeItemCollapsibleState_Expanded
    ),
    newLspItem(state, "Nimsuggest Pool", slotCount, "", TreeItemCollapsibleState_Expanded),
  ]
  if NIMBLE_RUN_TASK in state.lspExtensionCapabilities:
    rootItems.add(newLspItem(state, "Nimble Tasks", "", "", TreeItemCollapsibleState_Expanded))
  rootItems.add(newLspItem(state, "Notifications", "", "", TreeItemCollapsibleState_Expanded))
  return rootItems

proc initNimsuggestInstanceItem(
  state: ExtensionState, instance: NimsuggestStatus
): seq[LspItem] =
  # let errorCount = status.projectErrors.filterIt(it.entryPoint == instance.entryPoint).len
  # let errorLabel =
  #   if errorCount > 0: &"Project Errors ({errorCount})"
  #   else: "Project Errors"
  let openFileCount = if instance.openFiles.len == 0: "" else: $(instance.openFiles.len)
  var nsItems = @[
    newCheckProjectItem($(instance.entryPoint)),
    newLspItem(state, "Path", instance.path),
    newLspItem(state, "Version", $instance.version),
    newLspItem(state, "Protocol", $instance.protocol),
    newLspItem(state, "Port", $instance.port),
    newLspItem(state, "Open Files", openFileCount, "", TreeItemCollapsibleState_Collapsed, instance = some(instance)),
    # newLspItem(state, errorLabel, "", "", TreeItemCollapsibleState_Collapsed, instance = instance),
  ]
  # if NIMSUGGEST_RESTART in state.lspExtensionCapabilities:
  #   nsItems.insert(newRestartItem("Restart", $(instance.entryPoint), "restart"), 1)
  if NIMSUGGEST_STOP in state.lspExtensionCapabilities:
    nsItems.add(newNimsuggestStopItem($(instance.entryPoint)))
  return nsItems

proc getChildrenImpl(
  state: ExtensionState, element: LspItem = nil
): seq[LspItem] =
  # --- Root ---
  let self = state.statusProvider

  if element.isNil():
    return initRootItems(state, element)

  # --- Notifications (no status needed) ---
  elif element.label == "Notifications":
    return globalNotificationActionItems(state) &
      self.notifications.mapIt(newNotificationItem(it))
  elif element.isNotificationItem():
    return notificationActionItems(element)

  # --- Nimble Tasks (no status needed) ---
  elif element.label == "Nimble Tasks":
    var seen: seq[cstring]
    var groupItems: seq[LspItem] = @[newRefreshNimbleTasksItem()]
    for task in state.nimbleTasks:
      if task.projectDir notin seen:
        seen.add(task.projectDir)
        groupItems.add(
          newNimbleProjectItem(state, task.projectDir)
        )
    return groupItems
  elif element.nimbleProjectDir != "":
    let dir = element.nimbleProjectDir
    return state.nimbleTasks.filterIt($(it.projectDir) == dir).mapIt(newNimbleTaskItem(it))

  # --- Everything else requires status ---
  else:
    if self.status.isNone():
      return @[newLspItem(state, "Waiting for nimlangserver to init", "", "", TreeItemCollapsibleState_None)]

    let status = self.status.get()

    if element.label == "LSP Status":
      var lspStatusItems = @[
        newLspItem(state, "Path", $(status.exe.path)),
        newLspItem(state, "Version", status.exe.version),
        newLspItem(state, "Performance", $(status.performance.kind)),
        newLspItem(state, "Update-on-change", $(status.performance.updateOnChange)),
        newLspItem(state, "Request throttling", $(status.performance.fileCheckThrottling)),
      ]
      if SERVER_RESTART in state.lspExtensionCapabilities:
        lspStatusItems.add(newServerRestartItem())
      return lspStatusItems

    elif element.label == "Pending Requests":
      let reqs = status.pendingRequests
      if reqs.len == 0:
        return @[newLspItem(state, "None", "", "", TreeItemCollapsibleState_None)]
      return reqs.mapIt(
        newLspItem(state, it.name, "", "", TreeItemCollapsibleState_Expanded, pendingRequest = some it)
      )
    elif element.pendingRequest.isSome():
      let pr = element.pendingRequest.get()
      let timeTitle = if pr.state == "OnGoing": "Waiting for" else: "Took"
      var prItems = @[
        newLspItem(state, timeTitle, pr.time, "", TreeItemCollapsibleState_None),
        newLspItem(state, "State", pr.state, "", TreeItemCollapsibleState_None),
      ]
      if pr.entryPoint != FilePathAbs(""):
        prItems.add(newLspItem(state, "Nimsuggest", toRelPath($(pr.entryPoint)), "", TreeItemCollapsibleState_None))
      return prItems

    elif element.label == "Nimsuggest Pool":
      var items: seq[LspItem]
      # if NIMSUGGEST_RESTART in state.lspExtensionCapabilities:
      #   items.add(newRestartItem("Restart Server", "", "serverRestart"))
      items &= status.pool.mapIt(
        newLspItem(
          state, toRelPath($(it.entryPoint)), it.state, "", TreeItemCollapsibleState_Collapsed, some(it)
        )
      )
      return items

    elif element.label == "Open Files":
      if element.instance.isSome():
        let files = element.instance.get().openFiles
        if files.len == 0:
          return @[newLspItem(state, "None", "", "", TreeItemCollapsibleState_None)]
        return files.mapIt(newLspItem(state, toRelPath(it), "", "", TreeItemCollapsibleState_None))
      else:
        if status.openFiles.len == 0:
          return @[newLspItem(state, "None", "", "", TreeItemCollapsibleState_None)]

        return status.openFiles.mapIt(newLspItem(state, toRelPath($(it)), "", "", TreeItemCollapsibleState_None))

    elif element.label == "Project Errors" and element.instance.isSome():
    # elif ($element.label).startsWith("Project Errors") and element.instance.isSome():
      let entryPoint = element.instance.get().entryPoint
      let errors = status.projectErrors.filterIt(it.entryPoint == entryPoint)
      if errors.len == 0:
        return @[newLspItem(state, "None", "", "", TreeItemCollapsibleState_None)]
      return errors.mapIt(
        newLspItem(state, toRelPath($(it.entryPoint)), "", "", TreeItemCollapsibleState_Expanded, projectError = some it)
      )

    elif element.projectError.isSome():
      let pe = element.projectError.get()
      return @[
        newLspItem(state, "Error:", pe.errorMessage, "", TreeItemCollapsibleState_None),
        newLspItem(state, "Last Known Cmd:", pe.lastKnownCmd, "", TreeItemCollapsibleState_None),
      ]

    elif element.instance.isSome():
      # Per-instance children
      let instance = element.instance.get()
      return initNimsuggestInstanceItem(state, instance)
    
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

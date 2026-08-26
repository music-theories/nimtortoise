import std/[sequtils]
import ../platform/[vscodeApi, languageClientApi]
import ./[vscode_state_types]

proc refreshNotifications*(
  self: NimLangServerStatusProvider, notifications: seq[Notification]
) =
  self.notifications = notifications
  self.emitter.fire(nil)

proc onShowNotification*(message: cstring, detail: cstring) =
  ## VS Code spreads command.arguments, so handler receives (message, detail) as separate params.
  let detailStr = if not detail.isUndefined and detail != "".cstring: detail else: message
  vscode.window.showInformationMessage(
    message, VscodeMessageOptions(
      detail: detailStr, modal: true
    )
  )

proc onDeleteNotification*(state: ExtensionState, args: JsObject) =
  let id = args.to(cstring)
  let notifications = state.statusProvider.notifications.filterIt(it.id != id)
  state.statusProvider.refreshNotifications(notifications)

proc onClearAllNotifications*(state: ExtensionState) =
  refreshNotifications(state.statusProvider, @[])

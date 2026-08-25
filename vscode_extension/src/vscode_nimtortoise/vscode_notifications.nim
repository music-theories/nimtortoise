import std/[sequtils]
import ../platform/[vscodeApi, languageClientApi]
import ./[vscode_state_types]

proc refreshNotifications*(
  self: NimLangServerStatusProvider, notifications: seq[Notification]
) =
  self.notifications = notifications
  self.emitter.fire(nil)

proc onShowNotification*(args: JsObject) =
  ## args is [message, detail] — detail may be empty/undefined, falls back to message.
  let arr = args.to(seq[cstring])
  let title = arr[0]
  let detail = if arr.len > 1 and arr[1] != "".cstring: arr[1] else: arr[0]
  vscode.window.showInformationMessage(
    title, VscodeMessageOptions(
      detail: detail, modal: true
    )
  )

proc onDeleteNotification*(state: ExtensionState, args: JsObject) =
  let id = args.to(cstring)
  let notifications = state.statusProvider.notifications.filterIt(it.id != id)
  state.statusProvider.refreshNotifications(notifications)

proc onClearAllNotifications*(state: ExtensionState) =
  refreshNotifications(state.statusProvider, @[])

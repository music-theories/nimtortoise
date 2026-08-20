import std/[os, strutils, times, options, json, tables, sequtils, sugar]
import ../src/configurations/configurations
import ../src/langserver/langserver
import ../src/nimsuggest/nimsuggest
import ../src/protocol/[types]
import ../src/utils/utils
import ../src/utils/process_utils
import ../src/nimtortoise

import ../tests/lspsocketclient  # import without alias so we can selectively re-export
import chronos

# Re-export everything we need EXCEPT fixtureUri and createDidOpenParams, which we override.
export LspSocketClient, NotificationRpc, Rpc
export newLspSocketClient, notify, call, connect
export waitForNotification, waitForNotificationMessage
export registerNotification, positionParams, initialize, notificationHandle
export setWorkspaceConfig

export langserver_types, utils, process_utils, configurations, configuration_types,
  types, options, json, tables, sequtils, times, os, strutils, chronos

proc simpleProjectFile*(): string =
  absolutePath("tests" / "projects" / "simple" / "src" / "simple.nim")

proc simpleOrphanFile*(): string =
  absolutePath("tests" / "projects" / "simple" / "src" / "orphan.nim")

proc simpleOrphan2File*(): string =
  absolutePath("tests" / "projects" / "simple" / "src" / "orphan2.nim")

proc pkgaProjectFile*(): string =
  absolutePath("tests" / "projects" / "monorepo" / "pkga" / "src" / "pkga.nim")

proc pkgbProjectFile*(): string =
  absolutePath("tests" / "projects" / "monorepo" / "pkgb" / "src" / "pkgb.nim")

proc pkgaOrphanFile*(): string =
  absolutePath("tests" / "projects" / "monorepo" / "pkga" / "src" / "aorphan.nim")

proc dependenciesProjectFile*(): string =
  absolutePath("tests" / "projects" / "dependencies" / "src" / "dependencies.nim")

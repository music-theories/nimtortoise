# CLAUDE.md — vscode_extension

VS Code extension for Nim, LSP-only fork of [vscode-nim](https://github.com/nim-lang/vscode-nim). Written in Nim compiled to JS via the `js` backend. Cannot be installed simultaneously with the original `vscode-nim`.

## Build

| Task | Command |
|------|---------|
| Dev build (with source maps) | `nimble main` |
| Release build | `nimble release` |
| Package as VSIX | `nimble vsix` |
| Install VSIX locally | `nimble install_vsix` |

- Entry point: `src/vscode_nimtortoise.nim`
- Output: `out/vscode_nimtortoise.js` (the file VS Code loads as `main`)
- Nim requirement: `>= 2.0.0 & <= 2.1`
- Debug in VS Code: press **F5** — `.vscode/launch.json` runs `nimble build` then launches Extension Development Host

## Package identity (`package.json`)

| Field | Value |
|-------|-------|
| `name` | `vscode-nim-tortoise` |
| `displayName` | `Nim Tortoise` |
| `publisher` | `YOUR_PUBLISHER_ID` ← fill in before publishing |
| `repository` | `YOUR_REPO_URL` ← fill in before publishing |
| `main` | `./out/vscode_nim_tortoise.js` |

## Namespace — critical

All settings, commands, and context keys use the `nimTortoise` prefix. **Never use `nim`** — that belongs to the original extension.

| Type | Prefix | Example |
|------|--------|---------|
| Settings | `nimTortoise.` | `nimTortoise.lsp.path` |
| Commands | `nimTortoise.` | `nimTortoise.run.file` |
| Context keys | `nimTortoise:` | `nimTortoise:generatedFileExists` |
| LSP client ID | `nimTortoise` | first arg to `newLanguageClient(...)` |

```nim
vscode.workspace.getConfiguration("nimTortoise")
vscode.commands.registerCommand("nimTortoise.myCommand", handler)
```

`editorLangId == 'nim'` in `package.json` when-clauses is **correct** — refers to the Nim language ID, not this extension.

## LSP integration

`getLspPath` in `src/language_server/language_server.nim` resolves in order:
1. `nimTortoise.lsp.path` setting (user-specified)
2. `~/nimbledeps/bin/nimlangserver` (local install)
3. `nimlangserver` in PATH (global install)

Transport: `stdio` (default) or `socket` — `nimTortoise.transportMode`.
Client ID in VS Code Output panel: `"nimTortoise"` (label: `"Nim Tortoise Language Server"`).

## Source structure

```
src/
  vscode_nim_tortoise.nim            # activate/deactivate, command registration
  language_server/
    language_server.nim              # LSP startup, socket/stdio transport, inlay hints middleware
    language_configuration.nim       # Nim language config (brackets, comments, etc.)
  commands/
    compiler_commands.nim            # nim check, build
    debug_commands.nim               # CodeLLDB debug integration
    file_commands.nim                # run file, debug file, open generated file
    nimble_commands.nim              # nimble task code lenses and execution
    project_commands.nim             # nim.project / nim.projectMapping config handling; configUpdate
    test_commands.nim                # test runner integration (unittest2)
  state/
    state_types.nim                  # ExtensionState and all shared types
    state.nim                        # state accessors and helpers
  status_panel/
    nimStatus.nim                    # status bar item
    nimlspstatuspanel.nim            # tree view panel for LSP status and notifications
  tools/
    nimBinTools.nim                  # binary discovery: getBinPath, getNimExecPath, getAugmentedEnv
    nimUtils.nim                     # shared utilities; holds the global `ext: ExtensionState`
  platform/
    vscodeApi.nim                    # VS Code API bindings
    languageClientApi.nim            # vscode-languageclient bindings
    js/                              # Node.js API bindings (fs, path, cp, net, os, etc.)
```

## Extension state

`ExtensionState` (`src/state/state_types.nim`) — single shared state object, stored in `nimUtils.ext`, accessed via `import ../tools/nimUtils`.

Key fields:
- `config` — `nimTortoise` workspace configuration (set at activation; re-read on change via `project_commands.nim:configUpdate`)
- `client` — active `VscodeLanguageClient`
- `statusProvider` — tree data provider for the Nim side panel
- `lspExtensionCapabilities` — capabilities advertised by the connected LSP server

## Adding a new setting

1. Add to `contributes.configuration.properties` in `package.json` with key `nimTortoise.yourSetting`
2. Read in Nim: `vscode.workspace.getConfiguration("nimTortoise").getStr("yourSetting")`
3. If it should trigger config reload, handle it in `project_commands.nim:configUpdate`

## Adding a new command

1. Add to `contributes.commands` in `package.json` with id `nimTortoise.yourCommand`
2. Register in `src/vscode_nim_tortoise.nim:activate` via `vscode.commands.registerCommand(...)`
3. Add menu/keybinding entries to `package.json` if needed

## Bundling the language server binary

Platform-specific `.vsix` packages (separate per OS/arch) are the VS Code-recommended approach. To add a bundled binary, insert in `getLspPath` after the `lsp.path` check:

```nim
var langserverExec: cstring = "nimlangserver"
if process.platform == "win32": langserverExec = "nimlangserver.exe"
let bundledPath = state.ctx.asAbsolutePath(path.join("bin", langserverExec))
if isValidLspPath(bundledPath): return (bundledPath, lspPathBundled)
```

Place binary at `vscode_extension/bin/nimlangserver` (not excluded by `.vscodeignore`). Add `lspPathBundled` to `LSPInstallPathKind` in `state/state_types.nim`. See `langserver/rewrite_analysis/PACKAGING.md` for CI details.

## Before publishing

- Replace `YOUR_PUBLISHER_ID` in `package.json` (`name`, `author`, `publisher`)
- Replace `YOUR_REPO_URL` in `package.json` (`homepage`, `repository.url`, `bugs.url`)
- Sync `version` between `package.json` and `vscode_nim_tortoise.nimble`

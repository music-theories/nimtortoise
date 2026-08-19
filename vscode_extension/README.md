# Nim Tortoise Language Server Extension

## "Slow and steady wins the race"

A VS Code extension for the Nim programming language that prioritises correctness over speed.

This is the VS Code extension for the [Nim Tortoise Language Server](../langserver/README.md). It is a fork of [`vscode-nim`](https://github.com/nim-lang/vscode-nim) refactored to be **LSP-only** — direct nimsuggest integration has been removed, leaving a thin wrapper around the language server. This makes the extension simpler and more reliable, as all language intelligence lives in one well-tested place.

> **Note**: This extension **replaces** the original `vscode-nim` — the two cannot be installed simultaneously. If both are active, they will each try to start a language server for the same files.

---

## Installation

First, install [Visual Studio Code](https://code.visualstudio.com/) `1.99.0` or higher.

Install the extension via `Install from VSIX` in the command palette (`cmd-shift-p`) and choose the `.vsix` file built from this repository.

The following tools are required:

* **Nim compiler** — http://nim-lang.org
* **nimlangserver** (the Nim Tortoise language server binary) — built from the `langserver/` directory in this repository

---

## Developing the Extension

The extension is written in **Nim** and compiled to JavaScript using the `js` backend.

| Task | Command |
|------|---------|
| Dev build (with source maps) | `nimble main` |
| Release build | `nimble release` |
| Package as VSIX | `nimble vsix` |
| Install VSIX locally | `nimble install_vsix` |

To debug the extension in VS Code, press **F5** in the dev workspace. The `.vscode/launch.json` runs `nimble build` and then launches an Extension Development Host window running the patched extension. Open a Nim project there to test.

### Side-loading the Extension

* Run `nimble vsix` to build the extension package to `out/nimvscode-<version>.vsix`
* Run `nimble install_vsix` if you have VS Code on `PATH`, or select **Install from VSIX** from the command palette and choose the `.vsix` file.

Then choose the built `nimtortoise` binary as the langsuage server path in the settings.

---

## Acknowledgments

This extension started out as a fork of the [@saem](https://github.com/saem) extension [vscode-nim](https://github.com/saem/vscode-nim), which was itself a port of an extension written in [TypeScript](https://marketplace.visualstudio.com/items?itemName=kosz78.nim) by @kosz78 for the Nim language.

Thank you Saem for your work and letting us build on top of it.

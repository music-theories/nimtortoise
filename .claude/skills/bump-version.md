---
name: bump-version
description: Bump the version number across all nim_tortoise files (langserver nimble, vscode extension nimble, package.json, forest nimble)
---

You are bumping the version number for the nim_tortoise project. There are exactly four files that must stay in sync:

1. `langserver/nimtortoise.nimble` — line with `version = "X.Y.Z"`
2. `vscode_extension/vscode_nimtortoise.nimble` — line with `version = "X.Y.Z"`
3. `vscode_extension/package.json` — the `"version": "X.Y.Z"` field (near the top)
4. `forest/forest.nimble` — line with `version = "X.Y.Z"`
5. `api/api.nimble` — line with `version = "X.Y.Z"`

**Step 1 — Discover current versions.**
Read all three files and report the current version in each. Flag any mismatches.

**Step 2 — Determine target version.**
If the user supplied a version (e.g. `/bump-version 0.1.4`), use that. Otherwise ask: "What version should I bump to? Current versions are: [list]".

**Step 3 — Apply the changes.**
Update the version string in all three files to the target version. Use Edit (not Bash sed) so each change is visible in the diff.

**Step 4 — Verify.**
After editing, read back the relevant line from each file and confirm all three show the new version. Report a summary table:

| File | Old | New | Status |
|------|-----|-----|--------|
| langserver/nimtortoise.nimble | … | … | ✓ |
| vscode_extension/vscode_nimtortoise.nimble | … | … | ✓ |
| vscode_extension/package.json | … | … | ✓ |
| forest/forest.nimble | … | … | ✓ |
| api/api.nimble | … | … | ✓ |

Do not touch CHANGELOG.md, package-lock.json, .vscode/tasks.json, or any other file — those are not part of the version declaration.

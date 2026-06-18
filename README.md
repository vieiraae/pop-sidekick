# Pop Sidekick

A PopClip-style AI text assistant for macOS. Select text in any app and a
floating popup appears next to it with clipboard and AI actions, all powered by
the official **GitHub Copilot SDK** (`@github/copilot-sdk`).

Native SwiftUI/AppKit menu-bar app. AI work runs through a small bundled Node
sidecar that drives the Copilot SDK; the Swift app talks to it over NDJSON.

## Features

- **Compact bar** on selection: Cut, Copy, Paste, Clipboard history, Bookmarks,
  Proofread, Rewrite, Tasks menu, and Edit (expands the popup).
- **Clipboard history** — each item has Paste, Bookmark, and Edit actions.
- **Bookmarks** — each item has Paste, Unbookmark, Edit, and Delete actions.
- **Tasks**: Proofread, Rewrite, Use synonyms, Minor/Major revise, Describe,
  Answer, Explain, Expand, Summarize, plus your own custom tasks.
- **Edit panel**: editable text, Task / Tone / Format / Length pickers,
  additional instructions, model picker, a choices slider, and a run button.
  Each result offers Refine (send back to the editor), Copy, and Paste.
- **Pin** the window to keep it on top; open **Settings** from the popup.
- **Animated colorful border** while Copilot is working; **cancel** any time.
- Minimalist, icon-first UI using SF Symbols, translucent materials, and modern
  macOS controls.

## Requirements

- macOS 14+
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) at
  `/opt/homebrew/bin/copilot` (configurable), signed in (`copilot` once).
- Node.js 20+ (used to run the bundled Copilot SDK bridge).
- Swift toolchain (Xcode or Command Line Tools) to build.

## Build & run (from source)

```bash
./scripts/make_app.sh release
open "dist/Pop Sidekick.app"
```

On first launch, grant **Accessibility** permission when prompted (or via
**Settings → General → Permissions → Grant…**). This lets Pop Sidekick read the
current selection and apply clipboard actions. The menu-bar icon (sparkles)
gives access to the editor, settings, and quit.

### Develop

```bash
swift build          # compile
swift run            # run from the build dir (uses bridge/ in the repo)
```

## Package for distribution (.dmg)

To produce a single double-clickable installer that anyone can use:

```bash
./scripts/make_dmg.sh release
```

This builds the app and creates `dist/Pop Sidekick <version>.dmg` containing the
app and an **Applications** shortcut, so installing is a simple drag-and-drop.
Share that `.dmg` file.

### Installing (for end users)

1. Open the `.dmg` and drag **Pop Sidekick** onto the **Applications** folder.
2. The app is self-signed, not notarized, so the first launch needs a one-time
   Gatekeeper bypass: **right-click** (or Control-click) **Pop Sidekick** in
   Applications → **Open** → **Open** in the dialog. (Plain double-click shows a
   "cannot be opened" warning the first time.)
   - Alternatively, clear the quarantine flag from Terminal:
     ```bash
     xattr -dr com.apple.quarantine "/Applications/Pop Sidekick.app"
     ```
3. Grant **Accessibility** when prompted (System Settings → Privacy & Security →
   Accessibility), then open it from **Settings → General → Permissions**.
4. Make sure the **GitHub Copilot CLI** is installed and signed in (see
   Requirements). Set its path in **Settings → General** if it isn't at
   `/opt/homebrew/bin/copilot`.

> Note: Pop Sidekick runs the Copilot SDK bridge with Node and spawns your
> installed `copilot` binary; it does not bundle the CLI itself.

## How it works

```
Swift app  ──NDJSON over stdio──►  Node bridge (copilot-bridge.mjs)
   │                                     │ uses @github/copilot-sdk
   │                                     ▼
Accessibility API,                 CopilotClient ──► copilot CLI runtime
NSPanel popup, clipboard           (streaming deltas, abort, listModels,
                                    mcpServers, skillDirectories, systemMessage)
```

The bundled `node_modules` is pruned of the SDK's vendored CLI runtime because
Pop Sidekick spawns your installed `copilot` binary via an explicit path.

## Settings

- **General**: Copilot CLI path, default model, system message, clipboard
  history size, default result choices, auto-popup toggle.
- **Tasks**: create custom tasks (visual icon picker, name, instruction).
- **Advanced**: enable a skills folder; enable MCP servers from an `mcp.json`
  and toggle individual servers on/off.

Settings, clipboard history, and bookmarks persist under
`~/Library/Application Support/PopSidekick/`.

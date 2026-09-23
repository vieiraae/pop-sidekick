# Pop Sidekick

A PopClip-style AI text assistant for macOS. Select text in any app and a
floating popup appears next to it with clipboard and AI actions, powered by the
**GitHub Copilot SDK** (`@github/copilot-sdk`).

Native SwiftUI/AppKit menu-bar app. AI runs through a small bundled Node sidecar
that drives the Copilot SDK over NDJSON.

## Features

- **Compact bar** on selection: Cut, Copy, Paste (adapts to clipboard content),
  Clipboard, Bookmarks, Web search, quick tasks, Tasks picker, **Ask Copilot**,
  Edit.
- **Ask Copilot** — type how to transform the selection (e.g. "translate to
  Portuguese"), press ↩, result replaces the selection.
- **Web search** — search the selection with your browser's engine; configurable
  engines (Google, Bing, add your own via `%s`) with a default + dropdown.
- **Read-only aware** — on non-editable text, write actions (Cut/Paste) are
  hidden; tasks open the editor and run automatically.
- **Clipboard window** — a dedicated **History / Bookmarks** window (global
  hotkey) for text, rich text, images, files, links, with **search** and kind
  filter chips (text / rich / link / image / file). Double-click to paste
  (hold **⌥** to paste or copy as plain text);
  hover-revealed per-item actions: paste, copy, OCR / open / save image,
  **Edit with Copilot**, bookmark, delete. Compact image thumbnails expand into a
  floating full-size preview on hover. Concealed/transient clips (password
  managers) are never stored.
- **Tasks** — Proofread, Rewrite, Synonyms, Minor/Major revise, Describe, Answer,
  Explain, Expand, Summarize, plus custom tasks; bindable to global hotkeys.
- **Edit panel** — editable text (or an image preview attached on Run), Task /
  Tone / Format / Length pickers, extra instructions (↩ to run), model picker
  with a reasoning-effort (or Auto routing tier) menu, choices slider. Each result: Refine, Copy, Paste
  (⌥ = plain text).
- **Review changes** — revisions show an inline word-level diff (insertions in
  green, deletions struck through). Click any change to reject/restore it, or
  Accept all / Reject all; copy, paste, and refine use the cherry-picked text.
  Optional *Review AI changes before replacing text* (Settings → Behavior) makes
  quick actions open the diff instead of replacing the selection immediately.
- **Follow-ups** — revise a result conversationally ("shorter", "translate to
  Portuguese", or quick presets); each follow-up keeps the prior context and
  versions, with a back button to return to the previous version.
- **Models** — Copilot models or **BYOK** (OpenAI, Azure, Anthropic, Ollama,
  Foundry Local, OpenAI-compatible) with per-model Test Connection.
- **FocusTrace** — a presentation aid: magnifies the cursor under a liquid-glass
  halo, and dragging draws a colorful, glassy trace that fades away. Toggle from
  the menu bar or a global hotkey; drags can pass through, be captured, or draw
  only while ⌥ is held (Esc exits capture modes). Extras:
  - **Pinch magnifier** — spread two fingers on the trackpad to zoom a live lens
    where the cursor is (needs Screen Recording).
  - **Smart shapes** — ⇧-drag draws an arrow, ⇧⌥-drag draws a box, and
    circling or boxing something pins a clean ellipse/rectangle with **✕**
    (dismiss), **copy** (puts the screen content inside the shape on the
    clipboard as an image, without the ink), and **✨** (Copilot explains the
    circled region).
  - **Blank screen** — ⌃⌥B black / ⌃⌥W white on all screens, the pointer's
    screen, or a chosen display, doubling as a board to draw on.
  - Optional **spotlight**, **click ripples**, and **persistent ink**, all off by
    default. Hold ⌥ while dragging to keep just that stroke; ⌫ / ⌃Z / ⌘Z undo,
    ⌘⌫ clears.
- **Pin** on top, animated border while working, **cancel** any time, **Esc** to
  dismiss, onboarding on first launch.

## Selection capture

Selection is read entirely via the **Accessibility API** — the clipboard is
never touched. Browsers/Electron apps are woken on demand (`AXManualAccessibility`
/ `AXEnhancedUserInterface`) so their selections are readable too.

## Requirements

- macOS 14+
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) at
  `/opt/homebrew/bin/copilot` (configurable), signed in. Required even for BYOK —
  the runtime authenticates with your GitHub Copilot account.
- Node.js 20+
- Xcode (to build from source; the build scripts use its toolchain automatically)

## Install

Download the latest **`Pop Sidekick <version>.dmg`** from the
[Releases page](../../releases), open it, and drag the app onto **Applications**.
Official releases are signed with a Developer ID and notarized, so they open
without a Gatekeeper warning.

Or build from source:

```bash
./scripts/install.sh
```

On first launch, grant **Accessibility** when prompted (or via **Settings →
General → Permissions**). This lets Pop Sidekick read the selection and apply
clipboard actions.

## Build & run

```bash
./scripts/make_app.sh release      # build the app bundle
open "dist/Pop Sidekick.app"

swift build && swift run           # dev (uses bridge/ in the repo)
./scripts/make_dmg.sh release      # package a .dmg
```

## Release (maintainers)

```bash
./scripts/release.sh               # tags from the app version, e.g. v1.2.0
./scripts/release.sh v1.2.0        # or an explicit tag
```

For a notarized DMG, set `POPSIDEKICK_SIGN_ID` (Developer ID Application) and
`POPSIDEKICK_NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) before
running. Without them the DMG is self-signed (one-time Gatekeeper bypass needed).

## Settings

- **General** — Copilot CLI path, model source, default model, reasoning effort
  (low → max, clamped to what the model supports), Auto routing tier (Fast,
  Efficient, Balanced, Smartest), system message,
  clipboard history size, default choices, auto-popup, launch at login, web
  search engines, clipboard-window hotkey.
- **Models (BYOK)** — manage bring-your-own models with Test Connection.
- **Tasks** — custom tasks (icon, name, instruction) and global hotkeys.
- **FocusTrace** — on/off, toggle hotkey, cursor size, shape (system arrow,
  arrow, pointing hand, dot, ring, crosshair) and color, halo, drag behavior,
  color (or multicolor), line width, fade duration, persistent ink, smart
  shapes, click ripples and their size, spotlight radius and dim, magnifier lens size, blank-screen
  shortcuts, and Screen Recording permission status.
- **Advanced** — working folder, skills folder, and MCP servers from `mcp.json`
  with per-server toggles (applied to all Copilot tasks; disabled servers are
  passed to the SDK as `disabledMcpServers`, so they're also skipped when found
  via config discovery).
- **Security** — auto-approve tool requests (**off by default**: AI prompts
  include selected text, which can be untrusted).

## Security notes

- Tool/MCP/skill execution is **rejected by default**; opt in under Settings →
  Security.
- Settings (incl. BYOK keys), history, and bookmarks are stored under
  `~/Library/Application Support/PopSidekick/` with owner-only (`0600`)
  permissions. BYOK keys are kept in plaintext there (not the Keychain).

## How it works

```
Swift app  ──NDJSON over stdio──►  Node bridge (copilot-bridge.mjs)
   │                                     │ @github/copilot-sdk
   ▼                                     ▼
Accessibility API, NSPanel popup,   CopilotClient ──► copilot CLI runtime
clipboard                           (streaming, abort, BYOK, MCP, skills)
```

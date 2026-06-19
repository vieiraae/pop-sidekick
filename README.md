# Pop Sidekick

A PopClip-style AI text assistant for macOS. Select text in any app and a
floating popup appears next to it with clipboard and AI actions, powered by the
**GitHub Copilot SDK** (`@github/copilot-sdk`).

Native SwiftUI/AppKit menu-bar app. AI runs through a small bundled Node sidecar
that drives the Copilot SDK over NDJSON.

## Features

- **Compact bar** on selection: Cut, Copy, Paste (source / match style / plain),
  Clipboard history, Bookmarks, quick tasks, Tasks picker, **Ask Copilot**, Edit.
- **Ask Copilot** — type how to transform the selection (e.g. "translate to
  Portuguese"), press ↩, result replaces the selection.
- **Read-only aware** — on non-editable text, write actions (Cut/Paste) are
  hidden; tasks open the editor and run automatically.
- **Clipboard history & bookmarks** — text, rich text, images, files, links;
  per-item paste variants, OCR for images, bookmark/edit/delete. Items copied
  from password managers (concealed/transient) are never stored.
- **Tasks** — Proofread, Rewrite, Synonyms, Minor/Major revise, Describe, Answer,
  Explain, Expand, Summarize, plus custom tasks; bindable to global hotkeys.
- **Edit panel** — editable text, Task / Tone / Format / Length pickers, extra
  instructions, model picker, choices slider. Each result: Refine, Copy, Paste.
- **Models** — Copilot models or **BYOK** (OpenAI, Azure, Anthropic, Ollama,
  Foundry Local, OpenAI-compatible) with per-model Test Connection.
- **Pin** on top, animated border while working, **cancel** any time, onboarding
  on first launch.

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
- Swift toolchain (to build from source)

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
./scripts/release.sh               # tags from the app version, e.g. v1.1.0
./scripts/release.sh v1.2.0        # or an explicit tag
```

For a notarized DMG, set `POPSIDEKICK_SIGN_ID` (Developer ID Application) and
`POPSIDEKICK_NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) before
running. Without them the DMG is self-signed (one-time Gatekeeper bypass needed).

## Settings

- **General** — Copilot CLI path, model source, default model, system message,
  clipboard history size, default choices, auto-popup, launch at login.
- **Models (BYOK)** — manage bring-your-own models with Test Connection.
- **Tasks** — custom tasks (icon, name, instruction) and global hotkeys.
- **Advanced** — skills folder; MCP servers from `mcp.json` with per-server
  toggles.
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

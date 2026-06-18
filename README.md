# Pop Sidekick

A Popup-style AI text assistant for macOS. Select text in any app and a
floating popup appears next to it with clipboard and AI actions, all powered by
the official **GitHub Copilot SDK** (`@github/copilot-sdk`).

Native SwiftUI/AppKit menu-bar app. AI work runs through a small bundled Node
sidecar that drives the Copilot SDK; the Swift app talks to it over NDJSON.

## Features

- **Compact bar** on selection: Cut, Copy, Paste (with a style dropdown —
  source / match style / plain text), Clipboard history, Bookmarks, quick
  tasks, a Tasks picker, **Ask Copilot**, and Edit (expands the popup).
- **Ask Copilot** — a one-line prompt bar: type how to transform the selection
  (e.g. "translate to Portuguese"), press ↩, and the result replaces the
  selection automatically (just like a quick task).
- **Smart first actions** — when the selection is a folder, an **Open in Finder**
  button appears first; for a URL, an **Open Link** button appears.
- **Clipboard history** mirrors the system clipboard (Spotlight-style): text,
  rich text, images, files, and links. Copying with ⌘C anywhere makes the item
  available to paste from the popup. Per-item actions: Paste, Paste and Match
  Style, Paste as Plain Text, **Paste Extracted Text** (OCR for images via
  Copilot), Bookmark, Edit, Delete.
- **Bookmarks** — pin clipboard items; each has Paste, Unbookmark, Edit, Delete.
- **Tasks**: Proofread, Rewrite, Use synonyms, Minor/Major revise, Describe,
  Answer, Explain, Expand, Summarize, plus your own custom tasks. Tasks can be
  bound to global hotkeys.
- **Edit panel**: editable text, Task / Tone / Format / Length pickers,
  additional instructions, model picker, a choices slider, and a run button.
  Each result offers Refine (send back to the editor), Copy, and Paste.
- **Models**: use Copilot models, or **bring your own model (BYOK)** — configure
  a list of models from any supported provider (OpenAI, Azure, Anthropic,
  Ollama, Foundry Local, OpenAI-compatible) with a per-model Test Connection.
  The default-model picker lists your BYOK models first, then Copilot models.
- **Pin** the window to keep it on top; open **Settings** from the popup.
- **Animated colorful border** while Copilot is working; **cancel** any time.
- **Onboarding** guide on first launch.
- Minimalist, icon-first UI using SF Symbols, translucent materials, and modern
  macOS controls.

## Requirements

- macOS 14+
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) at
  `/opt/homebrew/bin/copilot` (configurable), signed in (`copilot` once).
- Node.js 20+ (used to run the bundled Copilot SDK bridge).
- Swift toolchain (Xcode or Command Line Tools) to build.

## Install

### Easiest: download the DMG

Grab the latest **`Pop Sidekick <version>.dmg`** from the
[Releases page](../../releases), open it, and drag **Pop Sidekick** onto
**Applications** — no toolchain or build required.

The released DMG is **signed with an Apple Developer ID and notarized by Apple**,
so it opens with no Gatekeeper warning. On first launch, grant **Accessibility**
when prompted (see below).

### From source: one command

```bash
./scripts/install.sh
```

This builds the app, installs it into **/Applications**, clears the Gatekeeper
quarantine flag (so no right-click "Open" dance), and launches it. Re-run it any
time to update to the latest build.

On first launch, grant **Accessibility** permission when prompted (or via
**Settings → General → Permissions → Grant…**). This lets Pop Sidekick read the
current selection and apply clipboard actions. The menu-bar icon (sparkles)
gives access to the editor, settings, and quit.

> Requires the Swift toolchain, Node.js, and npm (see Requirements). The script
> checks for them and tells you what's missing.

## Build & run (from source)

```bash
./scripts/make_app.sh release
open "dist/Pop Sidekick.app"
```

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

### Publish a GitHub Release (for maintainers)

To build the DMG and attach it to a GitHub Release in one step (requires the
[GitHub CLI](https://cli.github.com), authenticated via `gh auth login`):

```bash
./scripts/release.sh            # tags from the app version, e.g. v1.0.0
./scripts/release.sh v1.2.0     # or pass an explicit tag
./scripts/release.sh v1.2.0 --draft
```

The script builds `dist/Pop Sidekick <version>.dmg`, creates the release with
install notes, and uploads the DMG as a release asset. If the tag's release
already exists, it re-uploads the DMG (`--clobber`). Users then download it from
the [Releases page](../../releases).

#### Sign & notarize with an Apple Developer ID (no Gatekeeper warning)

By default the DMG is self-signed, so downloaders get a one-time Gatekeeper
prompt. To ship a DMG that opens cleanly, sign it with a **Developer ID
Application** certificate and notarize it with Apple. One-time setup:

1. Join the [Apple Developer Program](https://developer.apple.com/programs/).
2. Create a **Developer ID Application** certificate (Xcode → Settings →
   Accounts → Manage Certificates → **+**), so it lands in your keychain.
3. Create an [app-specific password](https://support.apple.com/102654) and store
   notarization credentials in the keychain:
   ```bash
   xcrun notarytool store-credentials "PopSidekick-Notary" \
     --apple-id "you@example.com" --team-id "TEAMID" \
     --password "app-specific-password"
   ```

Then build/release with the two environment variables set:

```bash
export POPSIDEKICK_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export POPSIDEKICK_NOTARY_PROFILE="PopSidekick-Notary"
./scripts/release.sh
```

`make_app.sh` signs the app (and its native node addon) with the hardened
runtime, and `make_dmg.sh` notarizes + staples both the app and the DMG. Find
your exact identity string with `security find-identity -p codesigning -v`.

### Installing (for end users)

1. Open the `.dmg` and drag **Pop Sidekick** onto the **Applications** folder.
2. If the DMG was **signed + notarized** (as the official Releases are), it opens
   normally — just double-click. If you distributed an **unsigned local build**
   instead, the first launch needs a one-time Gatekeeper bypass: **right-click**
   (or Control-click) **Pop Sidekick** in Applications → **Open** → **Open**.
   Alternatively clear the quarantine flag once:
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

```javascript
Swift app  ──NDJSON over stdio──►  Node bridge (copilot-bridge.mjs)
   │                                     │ uses @github/copilot-sdk
   │                                     ▼
Accessibility API,                 CopilotClient ──► copilot CLI runtime
NSPanel popup, clipboard           (streaming deltas, abort, listModels,
                                    BYOK provider config, ping, mcpServers,
                                    skillDirectories, systemMessage)
```

The bundled `node_modules` is pruned of the SDK's vendored CLI runtime because
Pop Sidekick spawns your installed `copilot` binary via an explicit path.

## Settings

- **General**: Copilot CLI path, model source (Copilot models or BYOK), default
  model, system message, clipboard history size, default result choices,
  auto-popup toggle, launch at login.
- **Models (BYOK)**: manage a list of bring-your-own models — pick a provider,
  fill in only the fields it needs (base URL, API key / bearer token, wire API,
  Azure API version), and use **Test Connection** to verify each one.
- **Tasks**: create custom tasks (visual icon picker, name, instruction) and
  assign global hotkeys.
- **Advanced**: enable a skills folder; enable MCP servers from an `mcp.json`
  and toggle individual servers on/off.

Settings, clipboard history, and bookmarks persist under
`~/Library/Application Support/PopSidekick/`.
#!/usr/bin/env bash
# One-command installer for Pop Sidekick: builds the app, installs it into
# /Applications, clears the Gatekeeper quarantine flag, and launches it.
#
# Usage:
#   ./scripts/install.sh            # build + install (release)
#   ./scripts/install.sh debug      # build + install a debug build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Pop Sidekick"
SRC_APP="$ROOT/dist/${APP_NAME}.app"
DEST_DIR="/Applications"
DEST_APP="$DEST_DIR/${APP_NAME}.app"

note() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preflight: required toolchain --------------------------------------------
command -v swift >/dev/null 2>&1 || fail "Swift toolchain not found. Install Xcode Command Line Tools:  xcode-select --install"
command -v node  >/dev/null 2>&1 || fail "Node.js not found. Install it (e.g.  brew install node) and re-run."
command -v npm   >/dev/null 2>&1 || fail "npm not found. Install Node.js (which includes npm) and re-run."

# --- Build --------------------------------------------------------------------
note "Building ${APP_NAME} ($CONFIG)"
"$ROOT/scripts/make_app.sh" "$CONFIG"
[ -d "$SRC_APP" ] || fail "Build did not produce $SRC_APP"

# --- Install into /Applications -----------------------------------------------
# If a running copy exists, quit it so the files can be replaced cleanly.
if pgrep -f "${APP_NAME}.app/Contents/MacOS/PopSidekick" >/dev/null 2>&1; then
  note "Quitting the running copy"
  osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
  sleep 1
fi

note "Installing to $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_DIR/"

# --- Clear quarantine so the first launch doesn't need a Gatekeeper bypass -----
note "Clearing the Gatekeeper quarantine flag"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

# --- Launch -------------------------------------------------------------------
note "Launching ${APP_NAME}"
open "$DEST_APP"

cat <<EOF

$(printf '\033[1;32m✓ Installed.\033[0m') ${APP_NAME} is in your Applications folder.

Next steps:
  1. Grant Accessibility when prompted (System Settings → Privacy & Security →
     Accessibility), so it can read selections and apply clipboard actions.
  2. Make sure the GitHub Copilot CLI is installed and signed in. Set its path
     in Settings → General if it isn't at /opt/homebrew/bin/copilot.
EOF

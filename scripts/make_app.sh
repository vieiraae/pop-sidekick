#!/usr/bin/env bash
# Builds Pop Sidekick.app: compiles the Swift binary, assembles the bundle,
# copies the Copilot SDK Node bridge (with node_modules), and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Pop Sidekick"
BUNDLE="$ROOT/dist/${APP_NAME}.app"

echo "==> Building Swift binary ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PopSidekick"

echo "==> Ensuring bridge dependencies are installed"
if [ ! -d "$ROOT/bridge/node_modules/@github/copilot-sdk" ]; then
  (cd "$ROOT/bridge" && npm install --omit=dev)
fi

echo "==> Assembling bundle at $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN" "$BUNDLE/Contents/MacOS/PopSidekick"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

echo "==> Copying Copilot SDK bridge"
mkdir -p "$BUNDLE/Contents/Resources/bridge"
cp "$ROOT/bridge/copilot-bridge.mjs" "$BUNDLE/Contents/Resources/bridge/"
cp "$ROOT/bridge/package.json" "$BUNDLE/Contents/Resources/bridge/"
cp -R "$ROOT/bridge/node_modules" "$BUNDLE/Contents/Resources/bridge/node_modules"

# The SDK depends on @github/copilot only for its own bundled runtime. We spawn
# the user's installed `copilot` via an explicit path, so prune the heavy
# runtime (~640MB) from the bundled copy to keep the app small.
echo "==> Pruning bundled CLI runtime"
rm -rf "$BUNDLE/Contents/Resources/bridge/node_modules/@github/copilot"
rm -rf "$BUNDLE"/Contents/Resources/bridge/node_modules/@github/copilot-darwin-*
rm -rf "$BUNDLE"/Contents/Resources/bridge/node_modules/@github/copilot-linux-*
rm -rf "$BUNDLE"/Contents/Resources/bridge/node_modules/@github/copilot-win32-*

# Drop dangling symlinks (e.g. node_modules/.bin/copilot) left by pruning, so the
# code signature seals cleanly and --deep --strict verification passes.
find "$BUNDLE/Contents/Resources/bridge/node_modules" -type l ! -exec test -e {} \; -delete 2>/dev/null || true

echo "==> Signing"
SIGN_ID="${POPSIDEKICK_SIGN_ID:-PopSidekick Dev}"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "    Using stable identity: $SIGN_ID (Accessibility grant persists across rebuilds)"
  codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
else
  echo "    No '$SIGN_ID' identity found; falling back to ad-hoc (grant resets each build)."
  codesign --force --deep --sign - "$BUNDLE"
fi

echo "==> Done: $BUNDLE"
echo "    Launch with: open \"$BUNDLE\""
echo "    Grant Accessibility permission when prompted (System Settings > Privacy & Security > Accessibility)."

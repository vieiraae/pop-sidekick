#!/usr/bin/env bash
# Builds Pop Sidekick.app and packages it into a distributable .dmg with a
# drag-to-Applications layout for simple installation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Pop Sidekick"
APP="$ROOT/dist/${APP_NAME}.app"
DMG="$ROOT/dist/${APP_NAME}.dmg"
STAGING="$ROOT/dist/dmg-staging"

echo "==> Building the app bundle"
"$ROOT/scripts/make_app.sh" "$CONFIG"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
[ -n "$VERSION" ] && DMG="$ROOT/dist/${APP_NAME} ${VERSION}.dmg"

echo "==> Staging disk image contents"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING"

echo "==> Done: $DMG"
echo "    Distribute this .dmg. Users open it and drag Pop Sidekick to Applications."

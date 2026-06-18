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

# --- Optional: Developer ID signing + Apple notarization ----------------------
# Set both to produce a DMG that opens with no Gatekeeper warning:
#   POPSIDEKICK_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#   POPSIDEKICK_NOTARY_PROFILE="<keychain profile from notarytool store-credentials>"
SIGN_ID="${POPSIDEKICK_SIGN_ID:-}"
NOTARY_PROFILE="${POPSIDEKICK_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && printf '%s' "$SIGN_ID" | grep -q "Developer ID"; then
  echo "==> Notarizing the app"
  # The app was already hardened-runtime signed by make_app.sh. Notarize it via
  # a zip, then staple the ticket so first launch works offline.
  APP_ZIP="$ROOT/dist/${APP_NAME}.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$APP_ZIP"

  echo "==> Rebuilding the DMG with the stapled app"
  rm -rf "$STAGING" "$DMG"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGING"

  echo "==> Signing and notarizing the DMG"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "    DMG is signed, notarized, and stapled (no Gatekeeper warning on download)."
elif printf '%s' "$SIGN_ID" | grep -q "Developer ID"; then
  echo "==> Note: POPSIDEKICK_NOTARY_PROFILE not set — skipping notarization."
  echo "    The app is Developer ID signed but not notarized; downloads still warn."
fi

echo "==> Done: $DMG"
echo "    Distribute this .dmg. Users open it and drag Pop Sidekick to Applications."

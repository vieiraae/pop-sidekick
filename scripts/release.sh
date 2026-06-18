#!/usr/bin/env bash
# Builds the distributable .dmg and publishes it as a GitHub Release using `gh`.
#
# Usage:
#   ./scripts/release.sh                # tag from the app version (e.g. v1.0.0)
#   ./scripts/release.sh v1.2.0         # explicit tag
#   ./scripts/release.sh v1.2.0 --draft # create the release as a draft
#
# Requires the GitHub CLI (`gh`) authenticated:  gh auth login
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pop Sidekick"
APP="$ROOT/dist/${APP_NAME}.app"

note() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || fail "GitHub CLI not found. Install it (brew install gh) and run: gh auth login"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"

# --- Build the .dmg -----------------------------------------------------------
note "Building the .dmg"
"$ROOT/scripts/make_dmg.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
[ -n "$VERSION" ] || fail "Could not read app version from $APP/Contents/Info.plist"

DMG="$ROOT/dist/${APP_NAME} ${VERSION}.dmg"
[ -f "$DMG" ] || fail "Expected DMG not found: $DMG"

# --- Resolve the tag ----------------------------------------------------------
TAG="${1:-v$VERSION}"
case "$TAG" in --*) TAG="v$VERSION" ;; esac   # first arg was a flag, not a tag
shift 2>/dev/null || true
EXTRA_FLAGS=("$@")

# --- Publish ------------------------------------------------------------------
NOTES="$(cat <<EOF
**${APP_NAME} ${VERSION}** — a PopClip-style AI text assistant for macOS.

### Install
1. Download \`${APP_NAME} ${VERSION}.dmg\` below and open it.
2. Drag **${APP_NAME}** onto **Applications**.
3. Launch it — the app is **signed with a Developer ID and notarized by Apple**,
   so it opens with no Gatekeeper warning.
4. Grant **Accessibility** when prompted, and make sure the GitHub Copilot CLI
   is installed and signed in.
EOF
)"

if gh release view "$TAG" >/dev/null 2>&1; then
  note "Release $TAG already exists — uploading the DMG to it"
  gh release upload "$TAG" "$DMG" --clobber
else
  note "Creating release $TAG"
  gh release create "$TAG" "$DMG" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES" \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
fi

note "Done. View it with:  gh release view $TAG --web"

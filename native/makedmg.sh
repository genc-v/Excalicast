#!/bin/bash
# Package Excalicast.app into a drag-and-drop .dmg (app + Applications shortcut).
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$NATIVE_DIR/dist/Excalicast.app"
DMG="$NATIVE_DIR/dist/Excalicast.dmg"
VOL="Excalicast"

if [ ! -d "$APP" ]; then
  echo "Excalicast.app not found — run: bash native/build.sh" >&2
  exit 1
fi

echo "==> Staging"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag target

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

rm -rf "$STAGE"

# Keep only the installer: remove the loose build app so it isn't a duplicate copy on disk /
# in Spotlight. Install by opening the .dmg and dragging to Applications.
rm -rf "$APP"

echo "==> Built $DMG (removed loose $APP — install via the .dmg)"

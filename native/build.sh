#!/bin/bash
# Build excali as a native macOS .app: build the web frontend, build the Swift executable,
# assemble the bundle, embed the web assets, and codesign with the stable self-signed identity.
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
APP="$NATIVE_DIR/dist/Excalicast.app"
IDENTITY="excali-selfsign"
KEYCHAIN="$HOME/Library/Keychains/excali-signing.keychain-db"

echo "==> Building web frontend"
cd "$ROOT_DIR"
npm run build

echo "==> Building Swift executable (release)"
cd "$NATIVE_DIR"
if [ -f "$HOME/.cargo/env" ]; then :; fi
swift build -c release
BIN="$NATIVE_DIR/.build/release/Excalicast"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/Excalicast"
cp -R "$ROOT_DIR/dist/." "$APP/Contents/Resources/web/"

if [ -f "$NATIVE_DIR/AppIcon.icns" ]; then
  cp "$NATIVE_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Excalicast</string>
  <key>CFBundleDisplayName</key><string>Excalicast</string>
  <key>CFBundleIdentifier</key><string>com.excalicast.app</string>
  <key>CFBundleExecutable</key><string>Excalicast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>ExcaliApplication</string>
</dict>
</plist>
PLIST

echo "==> Codesigning with $IDENTITY"
security unlock-keychain -p "excali-sign-pw" "$KEYCHAIN" 2>/dev/null || true
codesign --force --deep --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier" || true

echo "==> Built: $APP"

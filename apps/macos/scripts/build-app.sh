#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$MAC_DIR/../.." && pwd)"
APP_DIR="$MAC_DIR/build/HMTrans.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$MAC_DIR"
swift build -c release --product HMTransMac

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$MAC_DIR/.build/release/HMTransMac" "$MACOS_DIR/HMTrans"
cp "$ROOT_DIR/assets/app-icon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

RESOURCE_BUNDLE="$MAC_DIR/.build/out/Products/Release/HMTrans_HMTransMacApp.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>HMTrans</string>
  <key>CFBundleIdentifier</key>
  <string>com.linksc.hmtrans.mac</string>
  <key>CFBundleName</key>
  <string>HMTrans</string>
  <key>CFBundleDisplayName</key>
  <string>HMTrans</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>HMTrans needs local network access to discover and transfer files between your Mac and MatePad.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"

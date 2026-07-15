#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$MAC_DIR/../.." && pwd)"
APP_DIR="$MAC_DIR/build/HMTrans.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
GIT_TAG_VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
GIT_COMMIT_COUNT="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
VERSION="${HMT_VERSION:-${GIT_TAG_VERSION:-0.2.1}}"
BUILD_NUMBER="${HMT_BUILD_NUMBER:-${GIT_COMMIT_COUNT:-2}}"

if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  elif [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

cd "$MAC_DIR"
swift build --disable-sandbox -c release --product HMTransMac

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$MAC_DIR/.build/release/HMTransMac" "$MACOS_DIR/HMTrans"
cp "$ROOT_DIR/assets/app-icon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

RESOURCE_BUNDLE="$MAC_DIR/.build/out/Products/Release/HMTrans_HMTransMacApp.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>HMTrans needs local network access to discover and transfer files between your Mac and MatePad.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>用于显示当前连接的 Wi-Fi 网络名称，网络信息只在本机使用。</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>可发送的文件或文件夹</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.data</string>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"

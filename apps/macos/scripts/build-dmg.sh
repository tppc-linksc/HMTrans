#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$MAC_DIR/build"
APP_PATH="$BUILD_DIR/HMTrans.app"
DMG_PATH="$BUILD_DIR/HMTrans.dmg"
TEMP_DMG_PATH="$BUILD_DIR/HMTrans.tmp.dmg"
VOLUME_NAME="HMTrans"
ROOT_DIR="$(cd "$MAC_DIR/../.." && pwd)"
VOLUME_ICON_SOURCE_PATH="$ROOT_DIR/assets/app-icon/source.png"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hmtrans-icon.XXXXXX")"
VOLUME_ICON_PATH="$ICON_WORK_DIR/VolumeIcon.icns"
DEVICE_NAME=""
MOUNT_DIR=""

cleanup() {
  if [ -n "$DEVICE_NAME" ]; then
    hdiutil detach "$DEVICE_NAME" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$ICON_WORK_DIR"
  rm -f "$TEMP_DMG_PATH"
}

trap cleanup EXIT

detach_existing_volumes() {
  local volume_path
  while IFS= read -r volume_path; do
    hdiutil detach "$volume_path" -quiet >/dev/null 2>&1 || true
  done < <(find /Volumes -maxdepth 1 -type d -name "$VOLUME_NAME*" 2>/dev/null)
}

build_volume_icon() {
  local iconset_dir="$ICON_WORK_DIR/VolumeIcon.iconset"
  local icon_source_path="$VOLUME_ICON_SOURCE_PATH"
  local rounded_icon_source_path="$ICON_WORK_DIR/VolumeIconRounded.png"

  if ! command -v iconutil >/dev/null 2>&1 || ! command -v sips >/dev/null 2>&1; then
    cp "$ROOT_DIR/assets/app-icon/AppIcon.icns" "$VOLUME_ICON_PATH"
    return
  fi

  if command -v swift >/dev/null 2>&1; then
    swift - "$VOLUME_ICON_SOURCE_PATH" "$rounded_icon_source_path" <<'SWIFT'
import AppKit
import Foundation

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let canvasSize = NSSize(width: 1024, height: 1024)
let cornerRadius: CGFloat = 230

guard let sourceImage = NSImage(contentsOfFile: inputPath) else {
  exit(1)
}

let outputImage = NSImage(size: canvasSize)
outputImage.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()
let clipPath = NSBezierPath(
  roundedRect: NSRect(origin: .zero, size: canvasSize),
  xRadius: cornerRadius,
  yRadius: cornerRadius
)
clipPath.addClip()
sourceImage.draw(
  in: NSRect(origin: .zero, size: canvasSize),
  from: NSRect(origin: .zero, size: sourceImage.size),
  operation: .sourceOver,
  fraction: 1.0
)
outputImage.unlockFocus()

guard
  let tiffData = outputImage.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiffData),
  let pngData = bitmap.representation(using: .png, properties: [:])
else {
  exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
SWIFT
    icon_source_path="$rounded_icon_source_path"
  fi

  mkdir -p "$iconset_dir"
  sips -z 16 16 "$icon_source_path" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$icon_source_path" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$icon_source_path" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$icon_source_path" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$icon_source_path" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$icon_source_path" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$icon_source_path" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$icon_source_path" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$icon_source_path" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$icon_source_path" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset_dir" -o "$VOLUME_ICON_PATH"
}

apply_volume_icon() {
  local mounted_icon_path="$MOUNT_DIR/.VolumeIcon.icns"

  ditto "$VOLUME_ICON_PATH" "$mounted_icon_path"
  if [ ! -f "$mounted_icon_path" ]; then
    echo "Failed to write volume icon: $mounted_icon_path" >&2
    exit 1
  fi

  if command -v SetFile >/dev/null 2>&1; then
    SetFile -c icnC "$mounted_icon_path" || true
    SetFile -a V "$mounted_icon_path" || true
    SetFile -a C "$MOUNT_DIR" || true
  fi
}

detach_existing_volumes
bash "$SCRIPT_DIR/build-app.sh" >/dev/null
build_volume_icon

APP_SIZE_MB="$(du -sm "$APP_PATH" | awk '{ print $1 }')"
DMG_SIZE_MB="$((APP_SIZE_MB + 80))"

rm -f "$DMG_PATH" "$TEMP_DMG_PATH"
hdiutil create \
  -size "${DMG_SIZE_MB}m" \
  -volname "$VOLUME_NAME" \
  -ov \
  -fs HFS+ \
  "$TEMP_DMG_PATH" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG_PATH")"
DEVICE_NAME="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// { print $1; exit }')"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '{ start = index($0, "/Volumes/"); if (start > 0) { print substr($0, start); exit } }')"

if [ -z "$DEVICE_NAME" ] || [ -z "$MOUNT_DIR" ]; then
  echo "Failed to attach DMG volume: $TEMP_DMG_PATH" >&2
  printf '%s\n' "$ATTACH_OUTPUT" >&2
  exit 1
fi

ditto "$APP_PATH" "$MOUNT_DIR/HMTrans.app"
ln -s /Applications "$MOUNT_DIR/Applications"

sleep 2

osascript <<EOF >/dev/null
tell application "Finder"
  open disk "$VOLUME_NAME"
  delay 1
  set dmgWindow to container window of disk "$VOLUME_NAME"
  set current view of dmgWindow to icon view
  set toolbar visible of dmgWindow to false
  set statusbar visible of dmgWindow to false
  set bounds of dmgWindow to {160, 160, 840, 520}
  set theViewOptions to the icon view options of dmgWindow
  set icon size of theViewOptions to 128
  set text size of theViewOptions to 14
  tell disk "$VOLUME_NAME"
    set position of item "HMTrans.app" to {210, 155}
    set position of item "Applications" to {470, 155}
    update without registering applications
    delay 1
  end tell
  close dmgWindow
  open disk "$VOLUME_NAME"
end tell
delay 1
EOF

apply_volume_icon
sync
hdiutil detach "$DEVICE_NAME" -quiet
DEVICE_NAME=""
MOUNT_DIR=""
hdiutil convert "$TEMP_DMG_PATH" -ov -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TEMP_DMG_PATH"

echo "$DMG_PATH"

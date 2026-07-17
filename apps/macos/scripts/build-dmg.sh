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

# Validated Finder layout metadata for a 900 x 480 icon-view window. Embedding the
# metadata makes the DMG layout deterministic and avoids changing the user's
# Finder preferences while packaging.
DMG_LAYOUT_GZIP_BASE64='H4sICLurWWoAAy5EU19TdG9yZQDtl0FPE0EUgN+UIgsFu9IixINu0ngjuCRKMBxYFwxyUAhtEAJYd7vTumGZaXa3VCQkPevVxB/gH/DoH/DszZN69OzRm852XqUWOHiC6HzN5pvpvnk7M9vd6QAAsRveNIAOABpIp4fgVDQ8TpBC94uDJDm4K0rv3XrgR/HpuRQKxQVCPrtTbjOqu0H382uan0iqL91/aUCQGdgpPuPNYuzEjch2wq2kVuI8cDtlx133abOs5xc4ix2f0bDdwPeoCNl+7DOPN23eYF601XVCE5T1icPD6Rlz0pg1zaNJ4/CuKcq3Z82jI00bK9yaWyvvBnuMv5QdJgR7PtIzkldyJH5lH0dCXndG8hVHog0OZYZHLmf1K9nRbC6XH7s6PjFe1nOuU9mthUnvFnjAQzto0K1a6HvFulPxWW0jps/jov+ClvXRntA16j05/qp0UBcx+Z6YpZBS1s63Uq1GNN7oKm9uR2I2lmO6t8yqXOTfF7O4Uo99zqJ1GkbCm04YOqxG7YOdwHFpsMJsHsd8b8OvcCZ7lW0nEdXVkCYJCvPf5ZwUrM1OYVIWdCh0JkzL98wgKTHO6GDB8mR9ULz2b8IcLMEqUIjFDL+Bt/AOPsBH+ALf4AchZIjkyBi5Tm4Qk9whM2ReNk117tK1nktY8i7tF0MWcFZr1wCG4R7UxScAHyrgiGv5wIFBtBzwCv4uxRKVeiT8+WebdroMPICHUIJQtBHRMCUs8vzZisz0tFJI8B5pmfPthkKhuIAk7wcDbaFb0gTPp9DprjY62kBb6JY0wbgUOo3W0DraQFvoljS+tAhuPghemeAOhehoA2391ZAViv+GPik9Wf/vn73/VygU/zAkvVhctOH3huAEyVpriONppwGc/kcAY5OleAKOYw20hW5Jqz8CCsV58QvPTcYaBBgAAA=='

cleanup() {
  if [ -n "$DEVICE_NAME" ]; then
    diskutil eject "$DEVICE_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$ICON_WORK_DIR"
  rm -f "$TEMP_DMG_PATH"
}

trap cleanup EXIT

detach_existing_volumes() {
  local volume_path
  while IFS= read -r volume_path; do
    diskutil eject "$volume_path" >/dev/null 2>&1 || true
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
diskutil image create blank \
  --format RAW \
  --size "${DMG_SIZE_MB}m" \
  --volumeName "$VOLUME_NAME" \
  --fs APFS \
  "$TEMP_DMG_PATH" >/dev/null

ATTACH_OUTPUT="$(diskutil image attach --nobrowse "$TEMP_DMG_PATH")"
DEVICE_NAME="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// { print $1; exit }')"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '{ start = index($0, "/Volumes/"); if (start > 0) { print substr($0, start); exit } }')"

if [ -z "$DEVICE_NAME" ] || [ -z "$MOUNT_DIR" ]; then
  echo "Failed to attach DMG volume: $TEMP_DMG_PATH" >&2
  printf '%s\n' "$ATTACH_OUTPUT" >&2
  exit 1
fi

ditto "$APP_PATH" "$MOUNT_DIR/HMTrans.app"
ln -s /Applications "$MOUNT_DIR/Applications"

DS_STORE_PATH="$MOUNT_DIR/.DS_Store"
printf '%s' "$DMG_LAYOUT_GZIP_BASE64" | base64 -D | gzip -dc > "$DS_STORE_PATH"
if [ ! -s "$DS_STORE_PATH" ]; then
  echo "Failed to write the DMG Finder layout: $DS_STORE_PATH" >&2
  exit 1
fi

apply_volume_icon
sync
diskutil eject "$DEVICE_NAME" >/dev/null
DEVICE_NAME=""
MOUNT_DIR=""
diskutil image create from --format UDZO "$TEMP_DMG_PATH" "$DMG_PATH" >/dev/null
rm -f "$TEMP_DMG_PATH"

echo "$DMG_PATH"

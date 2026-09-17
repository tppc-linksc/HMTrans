#!/usr/bin/env bash
set -euo pipefail

ICON_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$ICON_DIR/../.." && pwd)"
SOURCE="$ICON_DIR/source.png"
WORK_DIR="$(mktemp -d /private/tmp/hmtrans-app-icon.XXXXXX)"
cleanup() {
  if [ "${HMTRANS_KEEP_ICON_WORK:-0}" = "1" ]; then
    echo "Icon work directory: $WORK_DIR" >&2
  else
    rm -r "$WORK_DIR"
  fi
}
trap cleanup EXIT

# Prefer a complete Xcode toolchain when the system-selected Command Line Tools
# compiler and macOS SDK come from different beta builds.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  fi
fi
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-cache"
export SWIFT_MODULE_CACHE_PATH="$WORK_DIR/swift-cache"

if [ ! -f "$SOURCE" ]; then
  echo "Missing icon master: $SOURCE" >&2
  exit 1
fi

# HarmonyOS and website touch icons use the complete square master. The platform
# applies its own launcher mask, so no rounded corners are baked into these PNGs.
sips -z 1024 1024 "$SOURCE" --out "$ICON_DIR/AppIcon-1024.png" >/dev/null
sips -z 432 432 "$SOURCE" --out \
  "$ROOT_DIR/apps/harmonyos/entry/src/main/resources/base/media/app_icon.png" >/dev/null
sips -z 192 192 "$SOURCE" --out "$ROOT_DIR/docs/site-assets/app-icon.png" >/dev/null

# macOS and the small website favicon need a transparent rounded-square mask.
swift - "$ICON_DIR/AppIcon-1024.png" "$WORK_DIR/rounded.png" <<'SWIFT'
import AppKit
import Foundation

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let canvasSize = NSSize(width: 1024, height: 1024)
let canvasRect = NSRect(origin: .zero, size: canvasSize)

guard let sourceImage = NSImage(contentsOfFile: inputPath) else { exit(1) }

let outputImage = NSImage(size: canvasSize)
outputImage.lockFocus()
NSColor.clear.setFill()
canvasRect.fill()
NSBezierPath(roundedRect: canvasRect, xRadius: 230, yRadius: 230).addClip()
sourceImage.draw(in: canvasRect, from: canvasRect, operation: .sourceOver, fraction: 1)
outputImage.unlockFocus()

guard let tiff = outputImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

sips -z 256 256 "$WORK_DIR/rounded.png" --out \
  "$ROOT_DIR/apps/macos/Sources/HMTransMacApp/Resources/AppIcon.png" >/dev/null
sips -z 192 192 "$WORK_DIR/rounded.png" --out "$ROOT_DIR/docs/site-assets/favicon.png" >/dev/null

# The menu-bar control needs the approved Möbius mark itself, not the white app
# icon tile. Extract the exact artwork from the square master with alpha and
# crop away unused margins so it remains legible at menu-bar size.
sips -z 512 512 "$SOURCE" --out "$WORK_DIR/menu-source.png" >/dev/null
swift - "$WORK_DIR/menu-source.png" \
  "$ROOT_DIR/apps/macos/Sources/HMTransMacApp/Resources/MenuBarLogo.png" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { exit(1) }

let width = image.width
let height = image.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
var inputPixels = [UInt8](repeating: 0, count: width * height * 4)
let didDraw = inputPixels.withUnsafeMutableBytes { bytes -> Bool in
    guard let context = CGContext(
        data: bytes.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard didDraw else { exit(1) }

func alphaAt(x: Int, y: Int) -> Double {
    let index = (y * width + x) * 4
    let distanceFromWhite = max(
        255 - Int(inputPixels[index]),
        255 - Int(inputPixels[index + 1]),
        255 - Int(inputPixels[index + 2])
    )
    return min(1, max(0, (Double(distanceFromWhite) - 3) / 19))
}

var minX = width
var minY = height
var maxX = -1
var maxY = -1
for y in 0..<height {
    for x in 0..<width where alphaAt(x: x, y: y) > 0.1 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else { exit(1) }

let padding = 12
minX = max(0, minX - padding)
minY = max(0, minY - padding)
maxX = min(width - 1, maxX + padding)
maxY = min(height - 1, maxY + padding)
let outputWidth = maxX - minX + 1
let outputHeight = maxY - minY + 1
var outputPixels = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
for y in 0..<outputHeight {
    for x in 0..<outputWidth {
        let sourceX = minX + x
        let sourceY = minY + y
        let sourceIndex = (sourceY * width + sourceX) * 4
        let outputIndex = (y * outputWidth + x) * 4
        let alpha = alphaAt(x: sourceX, y: sourceY)
        for channel in 0..<3 {
            let sourceValue = Double(inputPixels[sourceIndex + channel])
            outputPixels[outputIndex + channel] = UInt8(min(255, max(0, sourceValue - 255 * (1 - alpha))).rounded())
        }
        outputPixels[outputIndex + 3] = UInt8((alpha * 255).rounded())
    }
}

guard let provider = CGDataProvider(data: Data(outputPixels) as CFData),
      let outputImage = CGImage(
          width: outputWidth,
          height: outputHeight,
          bitsPerComponent: 8,
          bitsPerPixel: 32,
          bytesPerRow: outputWidth * 4,
          space: colorSpace,
          bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
          provider: provider,
          decode: nil,
          shouldInterpolate: true,
          intent: .defaultIntent
      ),
      let png = NSBitmapImageRep(cgImage: outputImage).representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT

ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir "$ICONSET"
sips -z 16 16 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$WORK_DIR/rounded.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
# Newly written iconset files are occasionally reported as invalid on the first
# immediate read by iconutil; let the filesystem settle and retry once.
sleep 2
if ! iconutil -c icns "$ICONSET" -o "$ICON_DIR/AppIcon.icns" 2>/dev/null; then
  sleep 2
  iconutil -c icns "$ICONSET" -o "$ICON_DIR/AppIcon.icns"
fi
cp "$ICON_DIR/AppIcon.icns" "$ROOT_DIR/apps/macos/Sources/HMTransMacApp/Resources/AppIcon.icns"

#!/bin/sh
set -eu
cd "$(dirname "$0")"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
iconset="$scratch/AppIcon.iconset"
mkdir "$iconset"
/usr/bin/swift -e '
import AppKit
let arguments = CommandLine.arguments
let dimension = 1024
guard let image = NSImage(contentsOfFile: arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension,
        pixelsHigh: dimension, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let bounds = NSRect(x: 0, y: 0, width: dimension, height: dimension)
context.cgContext.clear(bounds)
image.draw(in: bounds)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
' AppIcon.jpeg "$scratch/AppIcon.png"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$scratch/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    /usr/bin/sips -z "$doubled" "$doubled" "$scratch/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o AppIcon.icns

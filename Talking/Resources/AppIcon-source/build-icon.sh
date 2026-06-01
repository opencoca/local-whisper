#!/usr/bin/env bash
# Rebuild Talking/Resources/AppIcon.icns from AppIcon.svg.
#
# Run from anywhere; the script cds to its own directory first so the
# SVG's relative image references (sage-hex.png, sf-mic.png) resolve.
#
# Dependencies (all macOS or `brew install`):
#   - rsvg-convert  (SVG to PNG; resolves relative xlink:href correctly,
#                    unlike ImageMagick which delegates SVG via Inkscape
#                    and ends up rendering from a tmp dir where the
#                    referenced PNGs cannot be found)
#   - sips          (built-in, downscales the master PNG to iconset sizes)
#   - iconutil      (built-in, packs the iconset into a .icns)

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "Error: rsvg-convert not found. Install with: brew install librsvg"
    exit 1
fi

MASTER="AppIcon-1024.png"
ICONSET="AppIcon.iconset"
OUTPUT="../AppIcon.icns"

echo "Rendering SVG to ${MASTER}..."
rsvg-convert -w 1024 -h 1024 AppIcon.svg -o "${MASTER}"

echo "Building ${ICONSET}..."
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

# macOS iconutil expects this exact set of sizes:
sips -z 16   16   "${MASTER}" --out "${ICONSET}/icon_16x16.png"      >/dev/null
sips -z 32   32   "${MASTER}" --out "${ICONSET}/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "${MASTER}" --out "${ICONSET}/icon_32x32.png"      >/dev/null
sips -z 64   64   "${MASTER}" --out "${ICONSET}/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "${MASTER}" --out "${ICONSET}/icon_128x128.png"    >/dev/null
sips -z 256  256  "${MASTER}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "${MASTER}" --out "${ICONSET}/icon_256x256.png"    >/dev/null
sips -z 512  512  "${MASTER}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "${MASTER}" --out "${ICONSET}/icon_512x512.png"    >/dev/null
cp                "${MASTER}"          "${ICONSET}/icon_512x512@2x.png"

echo "Packing ${OUTPUT}..."
iconutil -c icns "${ICONSET}" -o "${OUTPUT}"

echo "Done."
echo "  Wrote: $(pwd)/${OUTPUT##*/}"
ls -la "${OUTPUT}"

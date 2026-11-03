#!/usr/bin/env bash
# Regenerates the website images in docs/assets from a Debug build: the picker over a mock desktop,
# window screenshots in light and dark, the icons and the social card. Needs Screen Recording for
# the terminal (screencapture), but never covers the screen.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/assets
mkdir -p "$OUT" build/demo build/shots

echo "→ Building Debug"
xcodegen generate --quiet
xcodebuild build -project Chroma.xcodeproj -scheme Chroma -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet

echo "→ Rendering the mock desktop"
swift Scripts/make-demo-backdrop.swift build/demo/backdrop.png >/dev/null

echo "→ Capturing"
./Scripts/shoot.sh build/demo/backdrop.png build/shots/picker.png "move 1287 411; zoom 15; size 200; hint" >/dev/null
for theme in light dark; do
  for window in library contrast menu settings-formats; do
    CHROMA_APPEARANCE=$theme ./Scripts/shoot.sh - "build/shots/$window-$theme.png" "window:$window" >/dev/null
  done
done

echo "→ Converting"
sips -s format jpeg -s formatOptions 82 build/shots/picker.png --out "$OUT/shot-picker.jpg" >/dev/null
for theme in light dark; do
  for window in library contrast menu settings-formats; do
    cp "build/shots/$window-$theme.png" "$OUT/shot-$window-$theme.png"
  done
done

ICNS="build/DerivedData/Build/Products/Debug/Chroma.app/Contents/Resources/AppIcon.icns"
sips -s format png -z 256 256 "$ICNS" --out "$OUT/icon-256.png" >/dev/null
sips -s format png -z 512 512 "$ICNS" --out build/shots/icon-512.png >/dev/null
sips -s format png -z 180 180 "$ICNS" --out "$OUT/apple-touch-icon.png" >/dev/null
swift Scripts/make-banner.swift build/shots/icon-512.png build/shots/picker.png "$OUT/og.png" >/dev/null
echo "✓ Assets in $OUT"

#!/usr/bin/env bash
# Builds NotchUtility.app into ./build using SwiftPM (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/NotchUtility.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NotchUtility" "$APP/Contents/MacOS/NotchUtility"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: render every size from the 1024px master and pack it into an .icns.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS privacy prompts (Automation, Calendar) attach to the bundle.
codesign --force --sign - "$APP"

echo "Built $APP"

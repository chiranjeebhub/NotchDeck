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

# Ad-hoc sign so macOS privacy prompts (Automation, Calendar) attach to the bundle.
codesign --force --sign - "$APP"

echo "Built $APP"

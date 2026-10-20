#!/usr/bin/env bash
# Builds NotchDeck.app into ./build using SwiftPM (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/NotchDeck.app"
# UNIVERSAL=1 builds for Apple silicon and Intel (release.sh sets it).
ARCH_FLAGS=()
CLANG_ARCHS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    CLANG_ARCHS=(-arch arm64 -arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NotchDeck" "$APP/Contents/MacOS/NotchDeck"
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

# System-wide Now Playing helper, run under /usr/bin/perl (see Adapter/MediaRemoteAdapter.m).
# The deployment target must match the app's, or older macOS versions refuse to load it.
clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.0 -framework Foundation ${CLANG_ARCHS[@]+"${CLANG_ARCHS[@]}"} \
    -o "$APP/Contents/Resources/MediaRemoteAdapter.dylib" Adapter/MediaRemoteAdapter.m
cp Adapter/MediaRemoteAdapter.pl "$APP/Contents/Resources/MediaRemoteAdapter.pl"
codesign --force --sign - "$APP/Contents/Resources/MediaRemoteAdapter.dylib"

# Ad-hoc sign so macOS privacy prompts (Automation, Calendar) attach to the bundle.
codesign --force --sign - "$APP"

echo "Built $APP"

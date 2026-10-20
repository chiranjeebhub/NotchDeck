#!/usr/bin/env bash
# Builds a Developer ID–signed, notarized NotchDeck-<version>.dmg in ./build.
#
# One-time setup:
#   1. Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application.
#   2. Store notarization credentials in the keychain (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials NotchDeck --apple-id <you@example.com> --team-id <TEAMID>
#
# Usage: scripts/release.sh            (IDENTITY and NOTARY_PROFILE can override the defaults)
#        SKIP_NOTARIZE=1 scripts/release.sh   to only sign and package.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-NotchDeck}"
APP="build/NotchDeck.app"
ENTITLEMENTS="Resources/NotchDeck.entitlements"

if [[ -z "$IDENTITY" ]]; then
    echo "No 'Developer ID Application' certificate found. Create one in Xcode → Settings → Accounts." >&2
    exit 1
fi
echo "Signing with: $IDENTITY"

scripts/build-app.sh

# Notarization needs every binary signed with the hardened runtime and a secure timestamp,
# innermost first.
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
    "$APP/Contents/Resources/MediaRemoteAdapter.dylib"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/NotchDeck-$VERSION.dmg"
STAGING="build/dmg"

# Drag-to-install disk image: the app next to a link to /Applications.
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "NotchDeck" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "Signed (not notarized): $DMG"
    exit 0
fi

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "Notarized: $DMG"

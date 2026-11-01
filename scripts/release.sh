#!/bin/bash
# Build a universal, Developer ID signed and Apple notarized UTUVO Wallpaper.
#
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE="…" bash scripts/release.sh
#
# NOTARY_PROFILE is a `xcrun notarytool store-credentials` keychain profile.
# Output: dist/UTUVO-Wallpaper-<version>.dmg, .zip and SHA256SUMS.txt

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

APP="$ROOT/Delivery/UTUVO Wallpaper.app"
DIST="$ROOT/dist"

ARCHS="arm64 x86_64" SIGN_IDENTITY="$SIGN_IDENTITY" bash "$ROOT/build.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="UTUVO-Wallpaper-${VERSION}"

rm -rf "$DIST"
mkdir -p "$DIST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 驗證簽章"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/WallpaperLab"

echo "==> 公證 App"
ditto -c -k --norsrc --keepParent "$APP" "$WORK/app.zip"
xcrun notarytool submit "$WORK/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$DIST/${NAME}.zip"

echo "==> DMG"
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/UTUVO Wallpaper.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "UTUVO Wallpaper" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DIST/${NAME}.dmg" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DIST/${NAME}.dmg"
xcrun notarytool submit "$DIST/${NAME}.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DIST/${NAME}.dmg"

echo "==> Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DIST/${NAME}.dmg"
xcrun stapler validate "$DIST/${NAME}.dmg"

(cd "$DIST" && shasum -a 256 "${NAME}.dmg" "${NAME}.zip" > SHA256SUMS.txt)
cat "$DIST/SHA256SUMS.txt"
echo "==> 完成：$DIST"

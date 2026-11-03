#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel) SwiftDesk.app and packages it as a drag-to-Applications disk image.
#
#   scripts/build-dmg.sh                                                     # ad-hoc signature
#   SIGN_IDENTITY="Apple Development: Name (TEAMID)" scripts/build-dmg.sh    # stable signature
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" TIMESTAMP=1 NOTARY_PROFILE=swiftdesk scripts/build-dmg.sh
#
# Environment:
#   SIGN_IDENTITY   passed to build-app.sh (app signature). Unset: ad-hoc app.
#                   The .dmg itself is signed only when notarizing (NOTARY_PROFILE set): Gatekeeper assesses a quarantined
#                   *signed* image when it is opened and rejects one that is not notarized ("could not be opened"),
#                   while an unsigned image mounts and only the app is assessed at first launch.
#   TIMESTAMP=1     secure timestamp (needed for notarization).
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials). Requires a Developer ID identity;
#                   when set, the dmg is notarized and stapled so it opens on other Macs without a Gatekeeper prompt.
#   ARCHS           default "arm64 x86_64".
#   OUTPUT_DIR      default <repo>/dist.
#
# Without Developer ID + notarization, macOS on the receiving Mac blocks the first launch; see "Read Me First.txt",
# which is copied into the image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
export ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
DMG="$OUTPUT_DIR/SwiftDesk-$VERSION.dmg"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/swiftdesk-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

OUTPUT_DIR="$WORK/app" SCRATCH_PATH="${SCRATCH_PATH:-$ROOT/.build/universal}" "$ROOT/scripts/build-app.sh"
APP="$WORK/app/SwiftDesk.app"
echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/SwiftDesk")"

echo "==> Staging disk image contents"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SwiftDesk.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/dmg-readme.txt" "$STAGE/Read Me First.txt"

echo "==> Creating $DMG"
mkdir -p "$OUTPUT_DIR"
rm -f "$DMG"
hdiutil create -quiet -volname "SwiftDesk $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    -ov "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    ts=(--timestamp=none); [[ "${TIMESTAMP:-0}" == "1" ]] && ts=(--timestamp)
    codesign --force --sign "$SIGN_IDENTITY" "${ts[@]}" "$DMG"
    echo "    dmg signed with \"$SIGN_IDENTITY\""
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (profile $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "==> Verifying"
hdiutil verify -quiet "$DMG"
MNT="$WORK/mnt"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
codesign --verify --strict --deep "$MNT/SwiftDesk.app" && echo "    app signature OK"
hdiutil detach -quiet "$MNT"

echo "SwiftDesk $VERSION ($BUILD): $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"

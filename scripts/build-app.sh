#!/usr/bin/env bash
# Builds SwiftDesk with SwiftPM (release) and assembles a signed build/SwiftDesk.app.
#
#   scripts/build-app.sh                       # ad-hoc signature (local testing only)
#   SIGN_IDENTITY="SwiftDesk Dev" scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" TIMESTAMP=1 scripts/build-app.sh
#
# Environment:
#   SIGN_IDENTITY  codesigning identity (name or SHA-1). Unset: ad-hoc ("-"), no hardened runtime.
#                  Set: hardened runtime (--options runtime) is enabled, as Developer ID distribution requires.
#   TIMESTAMP=1    add a secure timestamp (needs network; required for notarization).
#   SCRATCH_PATH   SwiftPM scratch directory (default: <repo>/.build).
#   ARCHS          space-separated architectures, e.g. "arm64 x86_64" for a universal binary (default: host arch).
#   OUTPUT_DIR     where SwiftDesk.app is written (default: <repo>/build).
#
# Why a stable signature matters: macOS keys Screen Recording / Accessibility grants (TCC) and keychain access to
# the app's code signature. An ad-hoc signature changes on every build, so macOS may ask again (or silently keep
# an old, now-stale grant) after each rebuild. See README.md, "Code signing and permissions".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    # xcode-select may point at the Command Line Tools, which lack the macOS SDK pieces this app needs.
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SCRATCH_PATH="${SCRATCH_PATH:-$ROOT/.build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build}"
APP="$OUTPUT_DIR/SwiftDesk.app"
INFO_PLIST="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Resources/SwiftDesk.entitlements"
APP_ICON="$ROOT/Resources/AppIcon.icns"

arch_args=()
for arch in ${ARCHS:-}; do arch_args+=(--arch "$arch"); done

echo "==> Building SwiftDesk (release${ARCHS:+, $ARCHS})"
swift build -c release --product SwiftDesk --package-path "$ROOT" --scratch-path "$SCRATCH_PATH" ${arch_args[@]+"${arch_args[@]}"}
BIN_DIR="$(swift build -c release --product SwiftDesk --package-path "$ROOT" --scratch-path "$SCRATCH_PATH" ${arch_args[@]+"${arch_args[@]}"} --show-bin-path)"
EXECUTABLE="$BIN_DIR/SwiftDesk"
[[ -x "$EXECUTABLE" ]] || { echo "error: $EXECUTABLE not found" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/SwiftDesk"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
# Info.plist names it via CFBundleIconFile = AppIcon. Regenerate with `swift scripts/make-icon.swift`.
cp "$APP_ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# SwiftPM resource bundles (none today) would sit next to the executable; copy any so Bundle.module keeps working.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

echo "==> Signing"
# Finder/iCloud metadata (com.apple.FinderInfo, resource forks) on a bundle makes codesign refuse to sign it.
xattr -cr "$APP"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    sign_args=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
    if [[ "${TIMESTAMP:-0}" == "1" ]]; then sign_args+=(--timestamp); else sign_args+=(--timestamp=none); fi
    codesign "${sign_args[@]}" "$APP"
    echo "    signed with \"$SIGN_IDENTITY\" (hardened runtime)"
else
    codesign --force --entitlements "$ENTITLEMENTS" --sign - --timestamp=none "$APP"
    echo "    ad-hoc signature: permissions may need to be granted again after each rebuild"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "$APP"

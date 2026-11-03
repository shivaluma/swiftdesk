#!/usr/bin/env bash
# Runs the whole test suite.
#
#   scripts/run-tests.sh                 # SwiftPM tests for every package target, then the AppUI tests
#   scripts/run-tests.sh --filter X      # extra arguments go to `swift test`
#   SKIP_APPUI=1 scripts/run-tests.sh    # SwiftPM tests only
#
# The AppUI tests (Tests/AppUITests) are not a SwiftPM test target yet, because Package.swift does not declare one.
# They run through the Xcode project's SwiftDeskTests bundle (project.yml), so they need XcodeGen's generated
# SwiftDesk.xcodeproj (checked in; regenerate with `xcodegen generate`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SCRATCH_PATH="${SCRATCH_PATH:-$ROOT/.build}"

status=0

echo "==> swift test"
swift test --package-path "$ROOT" --scratch-path "$SCRATCH_PATH" "$@" || status=$?

if [[ "${SKIP_APPUI:-0}" == "1" ]]; then
    exit "$status"
fi
if [[ ! -d "$ROOT/SwiftDesk.xcodeproj" ]]; then
    echo "==> Skipping AppUI tests: SwiftDesk.xcodeproj missing (run: xcodegen generate)"
    exit "$status"
fi

# Run the AppUI tests even if a package test failed, so one report covers everything.
echo "==> AppUI tests (xcodebuild test, scheme SwiftDesk)"
xcodebuild test \
    -project "$ROOT/SwiftDesk.xcodeproj" \
    -scheme SwiftDesk \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "${DERIVED_DATA_PATH:-$ROOT/.build/xcode}" \
    -quiet || status=$?

if [[ "$status" -ne 0 ]]; then
    echo "==> Some tests failed (exit $status)" >&2
fi
exit "$status"

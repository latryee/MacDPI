#!/bin/bash
# Explicit operator-run upload to Apple, never invoked by the normal build or CI.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 2 ]] || { echo 'Usage: scripts/notarize.sh ZIP_PATH KEYCHAIN_PROFILE' >&2; exit 2; }
app=build/release/MacDPI.app
codesign -dvv "$app" 2>&1 | /usr/bin/grep -q 'Authority=Developer ID Application' || { echo 'Developer ID signature required' >&2; exit 1; }
xcrun notarytool submit "$1" --keychain-profile "$2" --wait
xcrun stapler staple "$app"
REQUIRE_NOTARIZATION=1 scripts/verify-release.sh "$app"
scripts/package-release.sh --existing

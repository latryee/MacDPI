#!/bin/bash
# Explicit operator-run upload to Apple, never invoked by the normal build or CI.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && -n "$1" ]] || { echo 'Usage: scripts/notarize.sh KEYCHAIN_PROFILE' >&2; exit 2; }
build_root="${MACDPI_BUILD_ROOT:-build}"
python3 scripts/release-metadata.py check --build-root "$build_root"
app="$build_root/release/MacDPI.app"
python3 scripts/verify-packaging.py "$app" --require-production
stage="$(mktemp -d "$build_root/notarize.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
zip="$stage/MacDPI.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
python3 scripts/verify-packaging.py "$app" --require-production --zip "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$1" --wait --timeout 30m --output-format json > "$stage/result.json"
python3 - "$stage/result.json" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get('status') != 'Accepted':
    raise SystemExit(f"Apple notarization status: {result.get('status', 'unavailable')}")
PY
python3 scripts/verify-packaging.py "$app" --require-production --zip "$zip"
xcrun stapler staple "$app"
REQUIRE_NOTARIZATION=1 scripts/package-release.sh --existing --dmg

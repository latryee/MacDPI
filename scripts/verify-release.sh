#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-${MACDPI_BUILD_ROOT:-build}/release/MacDPI.app}"
python3 scripts/verify-packaging.py "$app"
if [[ "${REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
  python3 scripts/verify-packaging.py "$app" --require-production
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
else
  echo 'Gatekeeper/notarization acceptance is not asserted for a local build.'
fi

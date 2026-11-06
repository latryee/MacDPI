#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${MACDPI_BUILD_ROOT:-build}"
python3 scripts/release-metadata.py check --build-root "$build_root"
# The IDE archive is a local source/build review. The native release builder performs the
# explicit three-profile Developer ID validation and signing path; this command cannot activate it.
xcodebuild -project MacDPI.xcodeproj -scheme MacDPI -configuration Release \
  -derivedDataPath "$build_root/xcode" -archivePath "$build_root/archive/MacDPI.xcarchive" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  MACDPI_INTEGRATION_BUILD=local-review MACDPI_TEAM_PREFIX=UNPROVISIONED. archive

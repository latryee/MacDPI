#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project MacDPI.xcodeproj -scheme MacDPI -configuration Release \
  -derivedDataPath build/xcode -archivePath build/archive/MacDPI.xcarchive \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO archive

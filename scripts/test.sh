#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/reports
swift test --scratch-path build/swift
swift build --scratch-path build/swift -c release
xcrun swiftc -swift-version 5 Tools/TLSFixture/main.swift -o build/tls-fixture
python3 scripts/integration.py
scripts/build-app.sh
scripts/build-extension.sh

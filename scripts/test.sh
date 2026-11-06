#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/reports
swift test --scratch-path build/swift
python3 -m unittest discover -s Tests/PackagingTests
swift build --scratch-path build/swift -c release
xcrun swiftc -swift-version 5 Tools/TLSFixture/main.swift -o build/tls-fixture
python3 scripts/integration.py
python3 scripts/test-native-transports.py
scripts/build-app.sh

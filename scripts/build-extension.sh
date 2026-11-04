#!/bin/bash
# Build only. Never registers, installs, signs, or activates an extension.
set -euo pipefail
cd "$(dirname "$0")/.."
output="build/extension/io.github.latryee.MacDPI.TransparentProxy.systemextension"
mkdir -p "$output/Contents/MacOS" build/extension/arm64 build/extension/x86_64
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macos12.0" \
    -module-name MacDPITransparentProxy MacDPI/Core/*.swift Extension/TransparentProxyProvider.swift Extension/main.swift \
    -o "build/extension/$arch/MacDPITransparentProxy"
done
xcrun lipo -create build/extension/arm64/MacDPITransparentProxy build/extension/x86_64/MacDPITransparentProxy -output "$output/Contents/MacOS/MacDPITransparentProxy"
cp Extension/Info.plist "$output/Contents/Info.plist"
xcrun lipo -archs "$output/Contents/MacOS/MacDPITransparentProxy"
echo "Unsigned compile-only provider: $output. Team prefix/profiles/signing and integration approval still required."

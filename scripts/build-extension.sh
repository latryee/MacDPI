#!/bin/bash
# Build and sign inside the repository only. Never registers, installs, or activates an extension.
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${MACDPI_BUILD_ROOT:-build}"
python3 scripts/release-metadata.py check --build-root "$build_root"
mkdir -p "$build_root/extension/arm64" "$build_root/extension/x86_64"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  objects=()
  for source in IntegrationSupport/ControlChannel.m Extension/NetworkTransportBridge.m; do
    object="$build_root/extension/$arch/$(basename "${source%.m}").o"
    xcrun clang -fobjc-arc -fblocks -O2 -isysroot "$sdk" -target "$arch-apple-macos12.0" \
      -c "$source" -o "$object"
    objects+=("$object")
  done
  # Both separately signed provider bundles use the same source module, but advertise only
  # their own extension point and capability. Compile each architecture once and embed it twice.
  xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macos12.0" \
    -module-name MacDPITransparentProxy -import-objc-header Extension/NetworkTransportBridge.h \
    MacDPI/Core/*.swift Extension/*.swift "${objects[@]}" -framework Security \
    -o "$build_root/extension/$arch/MacDPIProviders"
done
for kind in extension dns; do
  if [[ "$kind" == extension ]]; then suffix=TransparentProxy; executable=MacDPITransparentProxy; else suffix=DNSProxy; executable=MacDPIDNSProxy; fi
  output="$build_root/extension/io.github.latryee.MacDPI.$suffix.systemextension"
  entitlements="$build_root/signing/$suffix.entitlements"
  python3 scripts/release-metadata.py prepare --kind "$kind" --bundle "$output" --entitlements "$entitlements"
  mkdir -p "$output/Contents/MacOS"
  xcrun lipo -create "$build_root/extension/arm64/MacDPIProviders" "$build_root/extension/x86_64/MacDPIProviders" -output "$output/Contents/MacOS/$executable"
  python3 scripts/release-metadata.py sign --kind "$kind" --bundle "$output" --entitlements "$entitlements"
  xcrun lipo -archs "$output/Contents/MacOS/$executable"
  echo "Prepared provider bundle: $output. This script never installs or activates it."
done

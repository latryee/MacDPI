#!/bin/bash
# Portable native build, retaining the original Xcode project for IDE development.
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${MACDPI_BUILD_ROOT:-build}"
python3 scripts/release-metadata.py check --build-root "$build_root"
app="$build_root/release/MacDPI.app"
if [[ "${MACDPI_PERSONAL_TUN:-0}" == 1 ]]; then
  if [[ -d "$app/Contents/Library/SystemExtensions" ]]; then
    echo 'Use a separate MACDPI_BUILD_ROOT for the personal TUN build.' >&2
    exit 1
  fi
else
  if [[ -d "$app/Contents/Helpers" ]]; then
    echo 'Use a separate MACDPI_BUILD_ROOT for the Network Extension build.' >&2
    exit 1
  fi
  scripts/build-extension.sh
fi
entitlements="$build_root/signing/Host.entitlements"
python3 scripts/release-metadata.py prepare --kind host --bundle "$app" --entitlements "$entitlements"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_root/native/arm64" "$build_root/native/x86_64" "$build_root/native/AppIcon.iconset"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun clang -fobjc-arc -fblocks -O2 -isysroot "$sdk" -target "$arch-apple-macos12.0" \
    -c IntegrationSupport/ControlChannel.m -o "$build_root/native/$arch/ControlChannel.o"
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -sdk "$sdk" \
    -target "$arch-apple-macos12.0" -module-name MacDPI \
    -import-objc-header IntegrationSupport/ControlChannel.h \
    MacDPI/Core/*.swift MacDPI/Models/*.swift MacDPI/ContentView.swift MacDPI/MacDPIApp.swift \
    "$build_root/native/$arch/ControlChannel.o" -framework Security \
    -o "$build_root/native/$arch/MacDPI"
done
xcrun lipo -create "$build_root/native/arm64/MacDPI" "$build_root/native/x86_64/MacDPI" -output "$app/Contents/MacOS/MacDPI"
for size in 16 32 128 256 512; do
  cp "MacDPI/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@1x.png" "$build_root/native/AppIcon.iconset/icon_${size}x${size}.png"
  cp "MacDPI/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@2x.png" "$build_root/native/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$build_root/native/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
if [[ "${MACDPI_PERSONAL_TUN:-0}" == 1 ]]; then
  scripts/build-tun-components.sh "$build_root" "$app"
else
  mkdir -p "$app/Contents/Library/SystemExtensions"
  for suffix in TransparentProxy DNSProxy; do
    ditto "$build_root/extension/io.github.latryee.MacDPI.$suffix.systemextension" "$app/Contents/Library/SystemExtensions/io.github.latryee.MacDPI.$suffix.systemextension"
  done
fi
# Nested code is signed first; local review hosts keep network-only sandbox permissions.
python3 scripts/release-metadata.py sign --kind host --bundle "$app" --entitlements "$entitlements"
scripts/verify-release.sh "$app"
echo "Verified Universal 2 application at $app."

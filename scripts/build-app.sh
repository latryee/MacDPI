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
swift_sources=(MacDPI/Core/*.swift MacDPI/Models/*.swift MacDPI/ContentView.swift MacDPI/MacDPIApp.swift)
if [[ "${MACDPI_PERSONAL_TUN:-0}" == 1 ]]; then
  scripts/build-tun-components.sh "$build_root" "$app"
  pin_source="$build_root/native/PersonalTUNBuildPins.swift"
  python3 - "$app" "$pin_source" <<'PY'
import hashlib
from pathlib import Path
import plistlib
import sys

contents = Path(sys.argv[1]) / 'Contents'
info_path = contents / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
pins = {}
for name in ('MacDPITUNHelper', 'MacDPITUNEngine'):
    binary = contents / 'Helpers' / name
    if not 0 < binary.stat().st_size <= 32 * 1024 * 1024:
        raise SystemExit(f'Personal TUN executable exceeds the staging bounds: {name}')
    pins[name] = hashlib.sha256(binary.read_bytes()).hexdigest()
info['MacDPITUNExecutableSHA256'] = pins
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
Path(sys.argv[2]).write_text(
    'enum PersonalTUNBuildPins {\n'
    f'    static let helper = "{pins["MacDPITUNHelper"]}"\n'
    f'    static let engine = "{pins["MacDPITUNEngine"]}"\n'
    '}\n'
)
PY
  swift_sources+=(-D MACDPI_PINNED_PERSONAL_TUN "$pin_source")
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun clang -fobjc-arc -fblocks -O2 -isysroot "$sdk" -target "$arch-apple-macos12.0" \
    -c IntegrationSupport/ControlChannel.m -o "$build_root/native/$arch/ControlChannel.o"
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -sdk "$sdk" \
    -target "$arch-apple-macos12.0" -module-name MacDPI \
    -import-objc-header IntegrationSupport/ControlChannel.h \
    "${swift_sources[@]}" \
    "$build_root/native/$arch/ControlChannel.o" -framework Security \
    -o "$build_root/native/$arch/MacDPI"
done
xcrun lipo -create "$build_root/native/arm64/MacDPI" "$build_root/native/x86_64/MacDPI" -output "$app/Contents/MacOS/MacDPI"
for size in 16 32 128 256 512; do
  cp "MacDPI/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@1x.png" "$build_root/native/AppIcon.iconset/icon_${size}x${size}.png"
  cp "MacDPI/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@2x.png" "$build_root/native/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$build_root/native/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
if [[ "${MACDPI_PERSONAL_TUN:-0}" != 1 ]]; then
  mkdir -p "$app/Contents/Library/SystemExtensions"
  for suffix in TransparentProxy DNSProxy; do
    ditto "$build_root/extension/io.github.latryee.MacDPI.$suffix.systemextension" "$app/Contents/Library/SystemExtensions/io.github.latryee.MacDPI.$suffix.systemextension"
  done
fi
# Nested code is signed first; local review hosts keep network-only sandbox permissions.
python3 scripts/release-metadata.py sign --kind host --bundle "$app" --entitlements "$entitlements"
scripts/verify-release.sh "$app"
echo "Verified Universal 2 application at $app."

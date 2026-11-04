#!/bin/bash
# Portable native build, retaining the original Xcode project for IDE development.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid VERSION' >&2; exit 2; }
app="build/release/MacDPI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/native/arm64 build/native/x86_64 build/native/AppIcon.iconset
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -sdk "$sdk" \
    -target "$arch-apple-macos12.0" -module-name MacDPI \
    MacDPI/Core/*.swift MacDPI/Models/*.swift MacDPI/ContentView.swift MacDPI/MacDPIApp.swift \
    -o "build/native/$arch/MacDPI"
done
xcrun lipo -create build/native/arm64/MacDPI build/native/x86_64/MacDPI -output "$app/Contents/MacOS/MacDPI"
for size in 16 32 128 256 512; do
  cp "MacDPI/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@1x.png" "build/native/AppIcon.iconset/icon_${size}x${size}.png"
  cp "MacDPI/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@2x.png" "build/native/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns build/native/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.latryee.MacDPI</string>
<key>CFBundleName</key><string>MacDPI</string>
<key>CFBundleDisplayName</key><string>MacDPI</string>
<key>CFBundleExecutable</key><string>MacDPI</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 MacDPI contributors. MIT License.</string>
</dict></plist>
PLIST
# Ad hoc signing only authenticates this local build's integrity; it is not a Developer ID release.
codesign --force --sign - --options runtime --entitlements MacDPI/App.entitlements "$app"
scripts/verify-release.sh "$app"
echo "Local ad hoc Universal 2 application: $app"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
existing=0
dmg=0
for option in "$@"; do
  case "$option" in --existing) existing=1;; --dmg) dmg=1;; *) echo 'Use --existing and/or --dmg' >&2; exit 2;; esac
done
app="build/release/MacDPI.app"
if [[ "$existing" == 0 ]]; then
  scripts/build-app.sh
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements MacDPI/App.entitlements "$app"
  fi
fi
scripts/verify-release.sh "$app"
version="$(cat VERSION)"
mkdir -p build/dist
label=local-adhoc
if codesign -dvv "$app" 2>&1 | /usr/bin/grep -q 'Authority=Developer ID Application'; then label=developer-id; fi
base="MacDPI-$version-universal2-$label"
ditto -c -k --sequesterRsrc --keepParent "$app" "build/dist/$base.zip"
artifacts=("$base.zip")
if [[ "$dmg" == 1 ]]; then
  mkdir -p build/dmg-root
  ditto "$app" build/dmg-root/MacDPI.app
  hdiutil create -ov -volname MacDPI -srcfolder build/dmg-root -format UDZO "build/dist/$base.dmg"
  artifacts+=("$base.dmg")
fi
(cd build/dist && shasum -a 256 "${artifacts[@]}" > "$base.sha256")
echo "Prepared $base. Nothing was uploaded or published."

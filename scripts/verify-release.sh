#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-build/release/MacDPI.app}"
test -d "$app"
plutil -lint "$app/Contents/Info.plist"
archs="$(xcrun lipo -archs "$app/Contents/MacOS/MacDPI")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo 'Missing Universal 2 slice' >&2; exit 1; }
codesign --verify --deep --strict "$app"
python3 - "$app" <<'PY'
import pathlib, plistlib, subprocess, sys
app=pathlib.Path(sys.argv[1])
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['LSMinimumSystemVersion']=='12.0'
assert info['CFBundleShortVersionString']==pathlib.Path('VERSION').read_text().strip()
result=subprocess.run(['codesign','-d','--entitlements','-','--xml',str(app)],capture_output=True)
if result.returncode:
    result=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True)
result.check_returncode()
ent=plistlib.loads(result.stdout)
assert set(ent)=={'com.apple.security.app-sandbox','com.apple.security.network.client','com.apple.security.network.server'},ent
assert all(ent.values())
assert not (app/'Contents/Library/SystemExtensions').exists(), 'Local release must not embed experimental extension'
print('Verified architecture slices, version, sandbox, least-privilege entitlements, and resource signature.')
PY
if [[ "${REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
else
  echo 'Gatekeeper/notarization acceptance is not asserted for a local build.'
fi

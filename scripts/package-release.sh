#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
existing=0
dmg=0
for option in "$@"; do
  case "$option" in --existing) existing=1;; --dmg) dmg=1;; *) echo 'Use --existing and/or --dmg' >&2; exit 2;; esac
done
build_root="${MACDPI_BUILD_ROOT:-build}"
python3 scripts/release-metadata.py check --build-root "$build_root"
app="$build_root/release/MacDPI.app"
if [[ "$existing" == 0 ]]; then
  scripts/build-app.sh
fi
scripts/verify-release.sh "$app"
version="$(cat VERSION)"
mkdir -p "$build_root/dist"
label=local-adhoc
mode=$(/usr/libexec/PlistBuddy -c 'Print :MacDPIIntegrationBuild' "$app/Contents/Info.plist")
case "$mode" in
  local-personal) label=personal-adhoc ;;
  developer-id) label=developer-id ;;
esac
base="MacDPI-$version-universal2-$label"
stage="$(mktemp -d "$build_root/package.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$base.zip"
artifacts=("$base.zip")
verify_args=(--zip "$stage/$base.zip")
if [[ "$dmg" == 1 ]]; then
  python3 - "$stage" "$app" "$base" <<'PY'
import pathlib, subprocess, sys, tempfile
root, app, base = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve(), sys.argv[3]
with tempfile.TemporaryDirectory(prefix='dmg-stage-', dir=root) as staging:
    subprocess.run(['ditto', str(app), str(pathlib.Path(staging)/'MacDPI.app')], check=True)
    subprocess.run(['hdiutil','create','-volname','MacDPI','-srcfolder',staging,'-format','UDZO',str(root/(base+'.dmg'))],check=True)
PY
  artifacts+=("$base.dmg")
  verify_args+=(--dmg "$stage/$base.dmg")
fi
python3 scripts/verify-packaging.py "$app" "${verify_args[@]}"
(cd "$stage" && shasum -a 256 "${artifacts[@]}" > "$base.sha256" && shasum -a 256 -c "$base.sha256")
for artifact in "${artifacts[@]}" "$base.sha256"; do
  mv -f "$stage/$artifact" "$build_root/dist/$artifact"
done
echo "Prepared $base. Nothing was uploaded or published."

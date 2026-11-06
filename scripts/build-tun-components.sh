#!/bin/bash
# Compile and ad hoc sign the two personal-use executables. No installation occurs.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 2 && "${MACDPI_PERSONAL_TUN:-0}" == 1 ]]
root="$PWD"
build_root="$1"
app="$2"
python3 scripts/release-metadata.py check --build-root "$build_root"
[[ "$app" == "$build_root/release/MacDPI.app" ]]
[[ -f "$app/Contents/Info.plist" && ! -L "$app/Contents/Helpers" && ! -L "$app/Contents/Resources/TUNLicenses" ]]
go_tool="${MACDPI_GO:-$root/build/tun-toolchain/go1.26.10/go/bin/go}"
[[ "$go_tool" = /* && -x "$go_tool" ]] || { echo 'Run scripts/fetch-tun-toolchain.sh first.' >&2; exit 1; }
export GOTOOLCHAIN=local GOFLAGS= GOPATH="$root/build/tun-gopath"
export GOMODCACHE="$root/build/tun-go-mod" GOCACHE="$root/build/tun-go-cache" GOWORK=off
[[ "$("$go_tool" env GOVERSION)" == go1.26.10 ]] || { echo 'Use the pinned Go 1.26.10 toolchain.' >&2; exit 1; }
mkdir -p "$build_root/tun" "$app/Contents/Helpers" "$app/Contents/Resources/TUNLicenses"
artifacts="$(cd "$build_root/tun" && pwd)"
licenses="$(cd "$app/Contents/Resources/TUNLicenses" && pwd)"
(cd Tools/TUNWorker && "$go_tool" mod download && "$go_tool" mod verify)
worker_mod="$(python3 Tools/TUNWorker/prepare-dependency.py "$GOMODCACHE" "$artifacts/gvisor-reviewed")"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  goarch="$arch"
  [[ "$arch" != x86_64 ]] || goarch=amd64
  target="$arch-apple-macos12.0"
  slice="$artifacts/$arch"
  mkdir -p "$slice"
  (
    cd Tools/TUNWorker
    GOOS=darwin GOARCH="$goarch" CGO_ENABLED=1 CC="xcrun clang -arch $arch" MACOSX_DEPLOYMENT_TARGET=12.0 \
      "$go_tool" build -p 3 -trimpath -mod=readonly -modfile "$worker_mod" -tags macdpi_archive \
      -buildmode=c-archive -o "$slice/libmacdpitun.a" .
  )
  for source in TUNNative TUNSessionIPC; do
    xcrun clang -O2 -Wall -Wextra -Werror -isysroot "$sdk" -target "$target" \
      -c "IntegrationSupport/$source.c" -o "$slice/$source.o"
  done
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -sdk "$sdk" -target "$target" \
    -import-objc-header IntegrationSupport/TUNHelperBridge.h -framework Security -framework SystemConfiguration \
    MacDPI/Core/TUNRoutePlanning.swift MacDPI/Core/TUNRouteTransaction.swift MacDPI/Core/TUNFileRouteJournalStore.swift \
    Tools/MacDPITUNHelper/*.swift "$slice/TUNNative.o" "$slice/TUNSessionIPC.o" -o "$slice/MacDPITUNHelper"
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -sdk "$sdk" -target "$target" \
    -import-objc-header Tools/MacDPITUNEngine/Bridge.h -framework Security -framework SystemConfiguration \
    MacDPI/Core/*.swift Tools/MacDPITUNEngine/*.swift "$slice/TUNSessionIPC.o" "$slice/libmacdpitun.a" \
    -o "$slice/MacDPITUNEngine"
done
for binary in MacDPITUNHelper MacDPITUNEngine; do
  destination="$app/Contents/Helpers/$binary"
  xcrun lipo -create "$artifacts/arm64/$binary" "$artifacts/x86_64/$binary" -output "$destination"
  chmod 0755 "$destination"
  codesign --force --sign - --options runtime "$destination"
done

# Package Go's standard library notice and the pinned dependencies' actual notices.
goroot="$("$go_tool" env GOROOT)"
install -S -m 0644 "$goroot/LICENSE" "$licenses/Go-LICENSE"
if [[ -f "$goroot/PATENTS" ]]; then install -S -m 0644 "$goroot/PATENTS" "$licenses/Go-PATENTS"; fi
(cd Tools/TUNWorker && "$go_tool" list -mod=readonly -m -f '{{if not .Main}}{{.Path}}|{{.Dir}}{{end}}' all) | \
while IFS='|' read -r module directory; do
  [[ -n "$module" && -n "$directory" ]] || continue
  name="${module//\//-}"
  for notice in LICENSE NOTICE PATENTS; do
    if [[ -f "$directory/$notice" ]]; then install -S -m 0644 "$directory/$notice" "$licenses/$name-$notice"; fi
  done
done

#!/bin/bash
# Build-time only. Verify the official archive before running its compiler.
set -euo pipefail
cd "$(dirname "$0")/.."

version=go1.26.10
case "$(uname -m)" in
  arm64) arch=arm64; digest=0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3 ;;
  x86_64) arch=amd64; digest=e820ab780c273ae4a340b79d0f3c4313b74ee029aa3874792145d44b9f4f91da ;;
  *) echo 'Unsupported Go build host architecture.' >&2; exit 1 ;;
esac

output="build/tun-toolchain/$version"
if [[ -x "$output/go/bin/go" ]]; then
  [[ "$(GOTOOLCHAIN=local "$output/go/bin/go" env GOVERSION)" == "$version" ]]
  exit
fi
mkdir -p build/tun-toolchain
stage="$(mktemp -d build/tun-toolchain.XXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
archive="$stage/$version.darwin-$arch.tar.gz"
curl --proto '=https' --tlsv1.2 --fail --location --max-time 180 \
  "https://go.dev/dl/$version.darwin-$arch.tar.gz" -o "$archive"
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$stage"
[[ "$(GOTOOLCHAIN=local "$stage/go/bin/go" env GOVERSION)" == "$version" ]]
mkdir "$output"
mv "$stage/go" "$output/go"

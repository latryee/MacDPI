#!/bin/bash
# No active tunnel or privileged network configuration. Synthetic IP packets and loopback only.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
go_tool="${MACDPI_GO:-$root/build/tun-toolchain/go1.26.10/go/bin/go}"
[[ "$go_tool" = /* && -x "$go_tool" ]] || { echo 'Run scripts/fetch-tun-toolchain.sh first.' >&2; exit 1; }
export GOTOOLCHAIN=local GOFLAGS= GOPATH="$root/build/tun-gopath"
export GOMODCACHE="$root/build/tun-go-mod" GOCACHE="$root/build/tun-go-cache" GOWORK=off
[[ "$("$go_tool" env GOVERSION)" == go1.26.10 ]]
mkdir -p build/tun-worker-tests
(cd Tools/TUNWorker && "$go_tool" mod download && "$go_tool" mod verify)
modfile="$(python3 Tools/TUNWorker/prepare-dependency.py "$GOMODCACHE" "$root/build/tun-worker-tests")"
cd Tools/TUNWorker
"$go_tool" test -p 3 -mod=readonly -modfile "$modfile" -timeout 90s -v "$@" .

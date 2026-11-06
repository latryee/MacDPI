#!/bin/bash
# Decode the live route table and query scoped routes without creating an interface or changing routes.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/macdpi-route-fixture.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
xcrun clang -std=c17 -Wall -Wextra -Werror -c IntegrationSupport/TUNNative.c -o "$scratch/TUNNative.o"
xcrun swiftc -swift-version 5 -import-objc-header IntegrationSupport/TUNNative.h \
  MacDPI/Core/TUNRoutePlanning.swift MacDPI/Core/TUNRouteTransaction.swift \
  Tools/MacDPITUNHelper/DarwinRouteBackend.swift Tools/TUNRouteFixture/main.swift \
  "$scratch/TUNNative.o" -o "$scratch/check"
"$scratch/check" "$@"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
scratch="$(mktemp -d "$(pwd -P)/build/tun-ipc.XXXXXX")"
trap 'rm -f -- "$scratch/fixture"; rmdir -- "$scratch"' EXIT
xcrun clang -std=gnu17 -Wall -Wextra -Werror -mmacosx-version-min=12.0 \
    Tests/NativeTUNIPC/main.c -o "$scratch/fixture" -framework Security -framework CoreFoundation
codesign --force --sign - "$scratch/fixture"
"$scratch/fixture"

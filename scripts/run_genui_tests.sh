#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/genui-tests"
mkdir -p "$OUT"
SDK=$(xcrun --show-sdk-path --sdk macosx)

swiftc -O -target arm64-apple-macos15.0 -sdk "$SDK" \
  Swash/GenUIBlock.swift Swash/WidgetTrustManager.swift Tests/GenUI/main.swift \
  -o "$OUT/runner"

"$OUT/runner"

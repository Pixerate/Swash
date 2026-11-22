#!/bin/bash
# Unit tests for SwashShareExtension's ShareContentConverter (HTML, RTF, Markdown, source links).
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
OUT="build/share"; mkdir -p "$OUT"
swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  $PIXERATE_MARKDOWN SwashShareExtension/ShareContentConverter.swift Tests/Share/main.swift -o "$OUT/runner"
"$OUT/runner"

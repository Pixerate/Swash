#!/bin/bash
# Unit tests for NewDocumentSeed window/document binding and claiming.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
OUT="build/new_document_seed"; mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
swiftc -O -DDEBUG -target arm64-apple-macos14.0 -sdk "$SDK" \
  $PIXERATE_MARKDOWN \
  Swash/DocumentOpening.swift \
  Tests/NewDocumentSeed/main.swift -o "$OUT/runner"
"$OUT/runner"

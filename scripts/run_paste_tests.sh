#!/bin/bash
# Checks for the engine's HTML paste conversion of Confluence and Jira images, which Swash relies on.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
OUT="build/paste"; mkdir -p "$OUT"
swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  $PIXERATE_MARKDOWN Tests/Paste/main.swift -o "$OUT/runner"
"$OUT/runner"

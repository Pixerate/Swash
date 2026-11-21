#!/bin/bash
# Checks for Swash's Shortcuts & App Intents engine (Swash/SwashAppIntents.swift):
# append/prepend, heading insertion, find/create, templates, HTML/Markdown/flavor conversion,
# to-do roll-ups, outline and statistics.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
OUT="build/shortcuts"; mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
EXTRAS="$(scripts/build_mac_appkit_extras.sh)"
swiftc $EXTRAS -O -target arm64-apple-macos14.0 -sdk "$SDK" \
  -DSWASH_SHORTCUTS_TEST_RUNNER \
  $PIXERATE_MARKDOWN \
  Swash/PlatformTypes.swift \
  Swash/MarkdownFlavor.swift \
  Swash/SlackMarkdown.swift \
  Swash/FolderIndex.swift \
  Swash/FolderAccessManager.swift \
  Swash/MarkdownParser.swift \
  Swash/SwashDocument.swift \
  Swash/SwashAppIntents.swift \
  Tests/Shortcuts/main.swift -o "$OUT/runner"
"$OUT/runner" "$OUT/fixture"

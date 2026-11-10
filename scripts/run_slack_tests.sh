#!/bin/bash
# Checks for Slack mrkdwn on the shared Markdown model: parsing (what Edit Text styles) and
# formatting with Slack's delimiters (Swash/SlackMarkdown.swift).
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
OUT="build/slack"; mkdir -p "$OUT"
swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  $PIXERATE_MARKDOWN Swash/MarkdownFlavor.swift Swash/PixerateMarkdownExtensions.swift Swash/SlackMarkdown.swift \
  Tests/Slack/main.swift -o "$OUT/runner"
"$OUT/runner"

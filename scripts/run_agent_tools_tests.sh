#!/bin/bash
# Calls each agent tool (Swash/MarkdownAgentTools.swift) through a PixerateCore ToolRegistry with
# valid and invalid arguments, as pixerate-mcp-bridge does (#49).
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
source scripts/pixerate_core.sh
OUT="build/agent-tools"; mkdir -p "$OUT"
# The app target's concurrency settings: Swift 5 mode, MainActor by default, approachable concurrency
swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  $PIXERATE_MARKDOWN $PIXERATE_CORE \
  Swash/MarkdownFlavor.swift Swash/PixerateMarkdownExtensions.swift Swash/SlackMarkdown.swift Swash/MarkdownAgentTools.swift Tests/AgentTools/main.swift -o "$OUT/runner"
"$OUT/runner"

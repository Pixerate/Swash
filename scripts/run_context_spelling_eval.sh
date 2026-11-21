#!/bin/bash
# Context-aware spelling eval (#98): injects wrong words into the strip-and-restore corpus
# (Tests/WritingPartnerEval/corpus) and scores what the on-device bandleader puts right. Needs
# macOS 26 with Apple Intelligence; elsewhere it says so and gives no score.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
source scripts/pixerate_account.sh
OUT="build/context-spelling-eval"; mkdir -p "$OUT"
swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  $PIXERATE_MARKDOWN $PIXERATE_ACCOUNT \
  Swash/MarkdownFlavor.swift Swash/SlackMarkdown.swift \
  Swash/WritingPartner.swift Swash/FormattingVoice.swift Swash/PartnerMarks.swift Swash/PixerateAccess.swift Swash/WritingBandleader.swift Swash/PixerateWritingBandleader.swift \
  Swash/OnDeviceWritingBandleader.swift \
  Tests/ContextSpellingEval/main.swift -o "$OUT/runner"
"$OUT/runner" --corpus Tests/WritingPartnerEval/corpus "$@"

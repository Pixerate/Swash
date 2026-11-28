#!/bin/bash
# Strip-and-restore evaluation for the writing partner's Punctuate voice (#106, #61):
# strips punctuation and casing from Tests/WritingPartnerEval/corpus, replays each document as
# keystrokes with a manual clock and a fixed fake spell checker, writes a Markdown report to
# build/writing-partner-eval/report.md, and checks scores against Tests/WritingPartnerEval/baseline.json.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
OUT="build/writing-partner-eval"
mkdir -p "$OUT"

swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  $PIXERATE_MARKDOWN \
  Swash/MarkdownFlavor.swift Swash/SlackMarkdown.swift Swash/WritingPartner.swift Swash/EditLayers.swift Swash/FormattingVoice.swift Swash/WritingBandleader.swift \
  Tests/WritingPartnerEval/main.swift -o "$OUT/runner"

"$OUT/runner" --report "$OUT/report.md" "$@"

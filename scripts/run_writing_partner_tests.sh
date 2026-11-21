#!/bin/bash
# Types text through the writing partner's Punctuate voice (Swash/WritingPartner.swift Swash/FormattingVoice.swift, #61) and
# checks its fixes: capital I, apostrophes, capitals at the start of sentences and paragraph-end
# punctuation, and that it leaves code, math, links' addresses, HTML and tables alone.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
source scripts/pixerate_account.sh
OUT="build/writing-partner"; mkdir -p "$OUT"
# The app target's concurrency settings: Swift 5 mode, MainActor by default, approachable concurrency
swiftc -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 -default-isolation MainActor -D DEBUG \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  $PIXERATE_MARKDOWN $PIXERATE_ACCOUNT \
  Swash/MarkdownFlavor.swift Swash/SlackMarkdown.swift \
  Swash/WritingPartner.swift Swash/FormattingVoice.swift Swash/PartnerMarks.swift Swash/PixerateAccess.swift Swash/WritingBandleader.swift Swash/PixerateWritingBandleader.swift \
  Swash/OnDeviceWritingBandleader.swift \
  Tests/WritingPartner/main.swift Tests/WritingPartner/FormattingTests.swift -o "$OUT/runner"
SPEC_FIXTURES="$PIXERATE_EDITOR/packages/swift/Tests/PixerateMarkdownTests/Fixtures" "$OUT/runner"

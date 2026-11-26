#!/bin/bash
# Context-aware spelling eval (#98): injects wrong words into the strip-and-restore corpus
# (Tests/WritingPartnerEval/corpus) and scores what the on-device bandleader puts right. Needs
# macOS 26 with Apple Intelligence; elsewhere it says so and gives no score.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_markdown.sh
source scripts/pixerate_account.sh
OUT="build/context-spelling-eval"; mkdir -p "$OUT"
# --all-candidates: build with offerThreshold 0 (in a copy) so the report lists the model's
# corrections below 0.5 too, to check the thresholds against (#167). Restored and offered then
# count those low-confidence corrections as well.
BANDLEADER=Swash/WritingBandleader.swift; ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--all-candidates" ]; then
    BANDLEADER="$OUT/WritingBandleader.swift"
    sed 's/static let offerThreshold = 0\.5$/static let offerThreshold = 0.0/' Swash/WritingBandleader.swift > "$BANDLEADER"
    grep -q 'static let offerThreshold = 0.0$' "$BANDLEADER" || { echo "couldn't lower offerThreshold in the copy" >&2; exit 1; }
  else
    ARGS+=("$arg")
  fi
done
swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  $PIXERATE_MARKDOWN $PIXERATE_ACCOUNT \
  Swash/MarkdownFlavor.swift Swash/SlackMarkdown.swift \
  Swash/WritingPartner.swift Swash/EditLayers.swift Swash/FormattingVoice.swift Swash/PartnerMarks.swift Swash/PixerateAccess.swift "$BANDLEADER" Swash/PixerateWritingBandleader.swift \
  Swash/OnDeviceWritingBandleader.swift \
  Tests/ContextSpellingEval/main.swift -o "$OUT/runner"
"$OUT/runner" --corpus Tests/WritingPartnerEval/corpus ${ARGS[@]+"${ARGS[@]}"}

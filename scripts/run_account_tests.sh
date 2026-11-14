#!/bin/bash
# Checks the Pixerate account gate (Swash/PixerateAccess.swift, #60) against a fake server: nothing
# is sent while signed out or with the feature off, and Fuel, rate-limit and sign-out replies.
set -eo pipefail
cd "$(dirname "$0")/.."
source scripts/pixerate_account.sh
OUT="build/account-tests"; mkdir -p "$OUT"
# The app target's concurrency settings: Swift 5 mode, MainActor by default, approachable concurrency
swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 -default-isolation MainActor -D DEBUG \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  $PIXERATE_ACCOUNT \
  Swash/PixerateAccess.swift Tests/PixerateAccount/main.swift -o "$OUT/runner"
"$OUT/runner"

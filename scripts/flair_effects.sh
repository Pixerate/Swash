#!/bin/bash
# Sourced after scripts/pixerate_core.sh by the runners that compile the writing partner's overlay
# (Swash/WritingPartnerOverlay.swift, #100): builds the part of Flair's Swift package it draws with
# (text treatments: the planner and its Core Animation renderer) as a FlairEffects module, so the
# swiftc runners can import it. Adds its flags to PIXERATE_CORE, which those runners already pass.
#
# Flair comes from the revision Package.resolved pins, fetched (sparsely) into build/pixerate-flair.
# To test against a local checkout instead, set PIXERATE_FLAIR_DIR. The package finds its treatments
# through SwiftPM's `Bundle.module`, which a plain swiftc build doesn't have, so a small shim points
# it at the checkout's Resources folder.

FLAIR_REPO_URL="https://github.com/Pixerate/flair.git"

flair_pinned_revision() {
  python3 - "Swash.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next(p["state"]["revision"] for p in pins if p["location"].rstrip("/").removesuffix(".git").lower().endswith("pixerate/flair")))
PY
}

if [[ -n "$PIXERATE_FLAIR_DIR" ]]; then
  PIXERATE_FLAIR="$(cd "$PIXERATE_FLAIR_DIR" && pwd)"
else
  PIXERATE_FLAIR="$PWD/build/pixerate-flair"
  flair_revision="$(flair_pinned_revision)"
  if [[ "$(git -C "$PIXERATE_FLAIR" rev-parse HEAD 2>/dev/null)" != "$flair_revision" ]]; then
    echo "Fetching FlairEffects at ${flair_revision:0:12}…" >&2
    if [[ ! -d "$PIXERATE_FLAIR/.git" ]]; then
      rm -rf "$PIXERATE_FLAIR"
      git clone --quiet --filter=blob:none --no-checkout "$FLAIR_REPO_URL" "$PIXERATE_FLAIR"
      git -C "$PIXERATE_FLAIR" sparse-checkout set --no-cone \
        /swift/Sources/FlairEffects/FlairTextTreatment.swift \
        /swift/Sources/FlairEffects/FlairTextTreatmentRenderer.swift \
        /swift/Sources/FlairEffects/Resources/flair-text-treatments.json
    fi
    git -C "$PIXERATE_FLAIR" fetch --quiet origin "$flair_revision"
    git -C "$PIXERATE_FLAIR" checkout --quiet --detach "$flair_revision"
  fi
fi

FLAIR_EFFECTS_SOURCES="$PIXERATE_FLAIR/swift/Sources/FlairEffects"
flair_files=("$FLAIR_EFFECTS_SOURCES/FlairTextTreatment.swift" "$FLAIR_EFFECTS_SOURCES/FlairTextTreatmentRenderer.swift")
for file in "${flair_files[@]}" "$FLAIR_EFFECTS_SOURCES/Resources/flair-text-treatments.json"; do
  if [[ ! -f "$file" ]]; then
    echo "error: $file not found" >&2
    exit 2
  fi
done

flair_hash="$(cat "${flair_files[@]}" "$FLAIR_EFFECTS_SOURCES/Resources/flair-text-treatments.json" | shasum | cut -c1-12)"
FLAIR_EFFECTS_DIR="$PWD/build/flair-effects/$flair_hash"
if [[ ! -f "$FLAIR_EFFECTS_DIR/libFlairEffects.a" ]]; then
  echo "Building FlairEffects…" >&2
  mkdir -p "$FLAIR_EFFECTS_DIR"
  cat > "$FLAIR_EFFECTS_DIR/BundleModule.swift" <<SWIFT
import Foundation
// In place of SwiftPM's resource accessor: the treatments' JSON, read from the checkout.
extension Bundle {
    static let module = Bundle(path: "$FLAIR_EFFECTS_SOURCES/Resources") ?? .main
}
SWIFT
  swiftc -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -module-name FlairEffects \
    -emit-module -emit-module-path "$FLAIR_EFFECTS_DIR/FlairEffects.swiftmodule" \
    -emit-library -static -o "$FLAIR_EFFECTS_DIR/libFlairEffects.a" \
    "${flair_files[@]}" "$FLAIR_EFFECTS_DIR/BundleModule.swift"
fi
PIXERATE_CORE="$PIXERATE_CORE -I $FLAIR_EFFECTS_DIR -L $FLAIR_EFFECTS_DIR -lFlairEffects"

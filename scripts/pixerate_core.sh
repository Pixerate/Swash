#!/bin/bash
# Sourced after scripts/pixerate_markdown.sh: builds the PixerateCore module (ToolRegistry, JSON
# Schema validation and the MCP bridge client, from the same editor checkout and revision) so the
# swiftc runners can import it. Sets:
#   PIXERATE_CORE  swiftc flags that import and link the module

PIXERATE_CORE_SOURCES="$PIXERATE_EDITOR/packages/swift/Sources/PixerateCore"
if [[ ! -d "$PIXERATE_CORE_SOURCES" && -z "$PIXERATE_EDITOR_DIR" ]]; then
  # Checkouts made before PixerateCore was needed don't include it in their sparse paths
  git -C "$PIXERATE_EDITOR" sparse-checkout add packages/swift/Sources/PixerateCore
fi
if [[ ! -d "$PIXERATE_CORE_SOURCES" ]]; then
  echo "error: $PIXERATE_CORE_SOURCES not found" >&2
  exit 2
fi

pixerate_core_files=()
while IFS= read -r file; do pixerate_core_files+=("$file"); done < <(find "$PIXERATE_CORE_SOURCES" -name '*.swift' | sort)
pixerate_core_hash="$(cat "${pixerate_core_files[@]}" | shasum | cut -c1-12)"
PIXERATE_CORE_DIR="$PWD/build/pixerate-core/$pixerate_core_hash"
if [[ ! -f "$PIXERATE_CORE_DIR/libPixerateCore.a" ]]; then
  echo "Building PixerateCore…" >&2
  mkdir -p "$PIXERATE_CORE_DIR"
  swiftc -O -parse-as-library -swift-version 6 \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -module-name PixerateCore \
    -emit-module -emit-module-path "$PIXERATE_CORE_DIR/PixerateCore.swiftmodule" \
    -emit-library -static -o "$PIXERATE_CORE_DIR/libPixerateCore.a" \
    "${pixerate_core_files[@]}"
fi
PIXERATE_CORE="-I $PIXERATE_CORE_DIR -L $PIXERATE_CORE_DIR -lPixerateCore"

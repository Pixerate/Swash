#!/bin/bash
# Sourced by the swiftc runners that need the Pixerate account client (#60): builds the public
# PixerateAccount package (github.com/Pixerate/PixerateAccount) at the revision Package.resolved
# pins, as the Xcode build does through SwiftPM. Sets:
#   PIXERATE_ACCOUNT  swiftc flags that import and link the module
# To test against a local checkout instead, set PIXERATE_ACCOUNT_SRC_DIR.

PIXERATE_ACCOUNT_REPO_URL="https://github.com/Pixerate/PixerateAccount.git"

if [[ -n "$PIXERATE_ACCOUNT_SRC_DIR" ]]; then
  PIXERATE_ACCOUNT_SRC="$(cd "$PIXERATE_ACCOUNT_SRC_DIR" && pwd)"
else
  PIXERATE_ACCOUNT_SRC="$PWD/build/pixerate-account-src"
  account_revision="$(python3 - "Swash.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next(p["state"]["revision"] for p in pins if p["location"].rstrip("/").removesuffix(".git").lower().endswith("pixerate/pixerateaccount")))
PY
)"
  if [[ "$(git -C "$PIXERATE_ACCOUNT_SRC" rev-parse HEAD 2>/dev/null)" != "$account_revision" ]]; then
    echo "Fetching PixerateAccount at ${account_revision:0:12}…" >&2
    if [[ ! -d "$PIXERATE_ACCOUNT_SRC/.git" ]]; then
      rm -rf "$PIXERATE_ACCOUNT_SRC"
      git clone --quiet --no-checkout "$PIXERATE_ACCOUNT_REPO_URL" "$PIXERATE_ACCOUNT_SRC"
    fi
    git -C "$PIXERATE_ACCOUNT_SRC" fetch --quiet origin "$account_revision"
    git -C "$PIXERATE_ACCOUNT_SRC" checkout --quiet --detach "$account_revision"
  fi
fi

pixerate_account_files=()
while IFS= read -r file; do pixerate_account_files+=("$file"); done < <(find "$PIXERATE_ACCOUNT_SRC/Sources/PixerateAccount" -name '*.swift' | sort)
pixerate_account_hash="$(cat "${pixerate_account_files[@]}" | shasum | cut -c1-12)"
PIXERATE_ACCOUNT_DIR="$PWD/build/pixerate-account/$pixerate_account_hash"
if [[ ! -f "$PIXERATE_ACCOUNT_DIR/libPixerateAccount.a" ]]; then
  echo "Building PixerateAccount…" >&2
  mkdir -p "$PIXERATE_ACCOUNT_DIR"
  swiftc -O -parse-as-library -swift-version 6 \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -module-name PixerateAccount \
    -emit-module -emit-module-path "$PIXERATE_ACCOUNT_DIR/PixerateAccount.swiftmodule" \
    -emit-library -static -o "$PIXERATE_ACCOUNT_DIR/libPixerateAccount.a" \
    "${pixerate_account_files[@]}"
fi
PIXERATE_ACCOUNT="-I $PIXERATE_ACCOUNT_DIR -L $PIXERATE_ACCOUNT_DIR -lPixerateAccount"

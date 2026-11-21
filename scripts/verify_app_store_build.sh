#!/usr/bin/env bash
set -euo pipefail

# verify_app_store_build.sh
# Verifies that an app bundle built for the Mac App Store is completely free of Sparkle artifacts:
# 1. No Sparkle.framework in Contents/Frameworks/
# 2. No Sparkle Info.plist keys (SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks)
# 3. No Sparkle dynamic library load commands in the Mach-O executable
# 4. No Sparkle Mach lookup exception entitlements

APP_PATH="${1:-}"

if [ -z "${APP_PATH}" ]; then
  echo "Usage: $0 <path-to-Swash.app>" >&2
  exit 1
fi

if [ ! -d "${APP_PATH}" ]; then
  echo "Error: App bundle not found at '${APP_PATH}'" >&2
  exit 1
fi

echo "==> Verifying App Store build at: ${APP_PATH}"

# 1. Check for Sparkle.framework inside the app bundle
if [ -d "${APP_PATH}/Contents/Frameworks/Sparkle.framework" ]; then
  echo "FAIL: Sparkle.framework found in ${APP_PATH}/Contents/Frameworks" >&2
  exit 1
fi
echo "  ✓ No Sparkle.framework in Contents/Frameworks"

# Also ensure no nested Sparkle frameworks anywhere in the bundle
SPARKLE_FRAMEWORKS=$(find "${APP_PATH}" -name "Sparkle.framework" 2>/dev/null || true)
if [ -n "${SPARKLE_FRAMEWORKS}" ]; then
  echo "FAIL: Sparkle.framework found in app bundle: ${SPARKLE_FRAMEWORKS}" >&2
  exit 1
fi
echo "  ✓ No Sparkle.framework anywhere in bundle"

# 2. Check Info.plist for Sparkle keys
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
if [ -f "${INFO_PLIST}" ]; then
  for KEY in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
    if /usr/libexec/PlistBuddy -c "Print :${KEY}" "${INFO_PLIST}" >/dev/null 2>&1; then
      echo "FAIL: Sparkle key '${KEY}' found in ${INFO_PLIST}" >&2
      exit 1
    fi
  done
  echo "  ✓ No Sparkle keys (SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks) in Info.plist"
else
  echo "FAIL: Info.plist not found at ${INFO_PLIST}" >&2
  exit 1
fi

# 3. Check Mach-O executable for Sparkle dynamic library load commands
EXECUTABLE="${APP_PATH}/Contents/MacOS/Swash"
if [ -f "${EXECUTABLE}" ]; then
  if otool -L "${EXECUTABLE}" 2>/dev/null | grep -i "Sparkle" >/dev/null; then
    echo "FAIL: Sparkle dynamic library load command found in ${EXECUTABLE}:" >&2
    otool -L "${EXECUTABLE}" | grep -i "Sparkle" >&2
    exit 1
  fi
  echo "  ✓ No Sparkle dynamic library load commands in executable"
else
  echo "FAIL: Executable not found at ${EXECUTABLE}" >&2
  exit 1
fi

# 4. Check embedded entitlements for Sparkle mach lookup exceptions
ENTITLEMENTS=$(codesign -d --entitlements :- "${APP_PATH}" 2>/dev/null || true)
if echo "${ENTITLEMENTS}" | grep -i -- "-spk" >/dev/null; then
  echo "FAIL: Sparkle temporary mach exception entitlements found in ${APP_PATH}" >&2
  exit 1
fi
echo "  ✓ No Sparkle Mach lookup exception entitlements"

echo "==> App Store build verification PASSED! Clean of Sparkle."

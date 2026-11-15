#!/usr/bin/env bash
# Captures the marketing site's screenshots in Light and Dark Mode
# (site/src/assets/screenshots/<shot>-<appearance>.png) from the Debug build of Swash editing the
# sample documents in site/sample. Same approach as generate_readme_screenshots.sh: only the copy
# of Swash this script launches is captured and quit. Needs Screen Recording permission for the
# terminal running it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/Swash.app"
SAMPLES="$ROOT/site/sample"
OUT="$ROOT/site/src/assets/screenshots"

if [ ! -d "$APP" ]; then
    xcodebuild -scheme Swash -destination 'generic/platform=macOS' -configuration Debug \
        -derivedDataPath "$ROOT/build/DerivedData" build CODE_SIGN_IDENTITY="-" >/dev/null
fi
mkdir -p "$OUT"

# shot <name> <sample document> <launch arguments…>
shot() {
    local name="$1" sample="$2"
    shift 2
    for appearance in light dark; do
        # Opened through Launch Services so the sandboxed app may read the file; the arguments
        # override the app's defaults for this launch only
        open -n -a "$APP" "$SAMPLES/$sample" --args -NSQuitAlwaysKeepsWindows NO \
            -suppressDefaultAppPrompt YES "$@" -appearance "$appearance"
        sleep 8
        local pid id
        pid="$(pgrep -n -f "$APP/Contents/MacOS/Swash")"
        id="$(swift "$ROOT/scripts/get_window_id.swift" "$pid")"
        screencapture -o -l "$id" "$OUT/$name-$appearance.png"
        kill "$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        echo "Wrote $OUT/$name-$appearance.png"
    done
}

shot editor "Field Notes.md" -showOutline YES -focusMode NO
shot focus "Field Notes.md" -showOutline NO -focusMode YES
shot rich "Launch Plan.md" -showOutline NO -focusMode NO

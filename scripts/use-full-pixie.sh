#!/bin/sh
# Swaps the open-source SwashPixie stub for the full package with Pixie (Packages/SwashPixieFull),
# for official releases and for developers with access to the private Pixerate/pixie repository.
# Symlinks are resolved (`cp -L`) so the shared interface file comes along as a real file.
# Undo with `git checkout -- Packages/SwashPixie Swash.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
# and `git clean -fd Packages/SwashPixie`.
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
cp -RL Packages/SwashPixieFull "$tmp/SwashPixie"
rm -rf Packages/SwashPixie
mv "$tmp/SwashPixie" Packages/SwashPixie
rmdir "$tmp"
test -f Packages/SwashPixie/Sources/SwashPixie/SwashPixieDocument.swift
grep -q 'isAvailable = true' Packages/SwashPixie/Sources/SwashPixie/SwashPixie.swift
echo "Packages/SwashPixie now has Pixie."

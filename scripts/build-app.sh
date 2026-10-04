#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/McDiff.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/McDiff" "$APP/Contents/MacOS/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset" "$PWD/Sources/McDiff/Resources/Lucide/git-compare-arrows.svg"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN"/*.bundle; do
    [[ -e "$bundle" ]] && rsync -a --delete "$bundle/" "$APP/Contents/Resources/$(basename "$bundle")/"
done
codesign --force --deep --sign "Developer ID Application: Respawn LLC (WY) (7L6T5KD8TA)" "$APP"
echo "$APP"

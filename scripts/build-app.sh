#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/Slopdiff.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Slopdiff" "$APP/Contents/MacOS/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset" "$PWD/Sources/Slopdiff/Resources/Lucide/git-compare-arrows.svg"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN"/*.bundle; do
    [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
codesign --force --deep --sign - "$APP"
echo "$APP"

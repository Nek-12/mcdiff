#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
APP="${1:?Usage: package-release.sh APP OUTPUT_DIRECTORY}"
OUTPUT="${2:?Usage: package-release.sh APP OUTPUT_DIRECTORY}"
ARCHIVE="McDiff-${VERSION}-macos-universal.zip"
[[ -d "$APP" ]] || { echo "App not found: $APP" >&2; exit 1; }
[[ "$(basename "$APP")" == McDiff.app ]] || { echo "Expected McDiff.app" >&2; exit 1; }
for KEY in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$APP/Contents/Info.plist")" == "$VERSION" ]] ||
        { echo "$KEY does not match VERSION" >&2; exit 1; }
done
for ARCH in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/McDiff" -verify_arch "$ARCH" ||
        { echo "Missing required architecture: $ARCH" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign -dv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Signature=adhoc"* ]] ||
    { echo "Public releases must be ad-hoc signed, without a Developer ID." >&2; exit 1; }
mkdir -p "$OUTPUT"
[[ ! -e "$OUTPUT/$ARCHIVE" && ! -e "$OUTPUT/SHA256SUMS" ]] ||
    { echo "Release output already exists; refusing to overwrite." >&2; exit 1; }
ditto -c -k --keepParent "$APP" "$OUTPUT/$ARCHIVE"
(cd "$OUTPUT" && shasum -a 256 "$ARCHIVE" > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
echo "$OUTPUT/$ARCHIVE"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/version.sh
source scripts/version.sh
ARCH=native
SIGN_IDENTITY=-
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:?Missing architecture}"; shift 2 ;;
        --sign) SIGN_IDENTITY="${2:?Missing signing identity}"; shift 2 ;;
        *) echo "Usage: $0 [--arch native|universal] [--sign IDENTITY]" >&2; exit 1 ;;
    esac
done
BUILD_ARGS=(-c release)
case "$ARCH" in
    native) ;;
    universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$PWD/dist/McDiff.app"
mkdir -p "$PWD/dist"
# Assemble from scratch so removed resources cannot leak into a later release.
STAGING="$(mktemp -d "$PWD/dist/.McDiff.XXXXXX")"
cleanup() {
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        /bin/rm -rf -- "$STAGING"
    else
        trash "$STAGING"
    fi
}
trap cleanup EXIT
mkdir -p "$STAGING/McDiff.app/Contents/MacOS" "$STAGING/McDiff.app/Contents/Resources"
cp "$BIN/McDiff" "$STAGING/McDiff.app/Contents/MacOS/"
cp scripts/Info.plist "$STAGING/McDiff.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGING/McDiff.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$STAGING/McDiff.app/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset" "$PWD/Sources/McDiff/Resources/Lucide/git-compare-arrows.svg"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$STAGING/McDiff.app/Contents/Resources/AppIcon.icns"
for bundle in "$BIN"/*.bundle; do
    [[ ! -e "$bundle" ]] || ditto "$bundle" "$STAGING/McDiff.app/Contents/Resources/$(basename "$bundle")"
done
LICENSES="$STAGING/McDiff.app/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp LICENSE "$LICENSES/LICENSE"
cp NOTICE "$LICENSES/NOTICE"
cp .build/checkouts/Highlightr/LICENSE "$LICENSES/Highlightr-LICENSE"
cp .build/checkouts/Highlightr/src/assets/highlighter/LICENSE "$LICENSES/highlight.js-LICENSE"
cp .build/checkouts/swift-markdown/LICENSE.txt "$LICENSES/swift-markdown-LICENSE.txt"
cp .build/checkouts/swift-markdown/NOTICE.txt "$LICENSES/swift-markdown-NOTICE.txt"
cp .build/checkouts/swift-cmark/COPYING "$LICENSES/swift-cmark-COPYING"
# Keep the bundled JS's newer copyright header alongside its original BSD license.
awk '
    NR == 1 && $0 != "/*!" { exit 1 }
    { print }
    /^[[:space:]]*\*\// { found = 1; exit }
    END { if (!found) exit 1 }
' .build/checkouts/Highlightr/src/assets/highlighter/highlight.min.js > "$LICENSES/highlight.js-NOTICE"
codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGING/McDiff.app"
codesign --verify --deep --strict "$STAGING/McDiff.app"
if [[ -e "$APP" ]]; then
    mv "$APP" "$STAGING/previous.app"
fi
mv "$STAGING/McDiff.app" "$APP"
echo "$APP"

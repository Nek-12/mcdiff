#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
RELEASES="${1:?Usage: next-version.sh RELEASES_JSON}"
ORIGINAL="$VERSION"
while true; do
    STATE="$(jq -er --arg tag "v$VERSION" \
        '[.[] | select(.tag_name == $tag)] | if length == 0 then "missing" elif .[0].draft then "draft" else "published" end' "$RELEASES")"
    case "$STATE" in
        draft) echo "Draft v$VERSION already exists. Resolve or remove the incomplete draft, then dispatch a fresh release." >&2; exit 1 ;;
        published)
            PREFIX="${VERSION%.*}"
            PATCH="${VERSION##*.}"
            VERSION="$PREFIX.$((PATCH + 1))"
            ;;
        missing)
            if git -C "$ROOT" show-ref --verify --quiet "refs/tags/v$VERSION"; then
                echo "Tag v$VERSION exists without a published release. Resolve the tag, then dispatch a fresh release." >&2
                exit 1
            fi
            break
            ;;
    esac
done
echo "$VERSION" > "$ROOT/VERSION"
echo "version=$VERSION"
if [[ "$VERSION" == "$ORIGINAL" ]]; then
    echo "bumped=false"
else
    echo "bumped=true"
fi

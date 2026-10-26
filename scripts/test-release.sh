#!/bin/bash
# Exercises real archives and failure paths; run after package-release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/version.sh
source scripts/version.sh
ROOT="$PWD"
WORK="$(mktemp -d)"
cleanup() {
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        /bin/rm -rf -- "$WORK"
    else
        trash "$WORK"
    fi
}
trap cleanup EXIT
OUTPUT="$ROOT/dist/release"
ARCHIVE="$OUTPUT/McDiff-$VERSION-macos-universal.zip"
fail() { echo "$*" >&2; exit 1; }
expect_failure() {
    local message="$1"
    shift
    if "$@" > "$WORK/failure.log" 2>&1; then
        fail "Unexpected success: $*"
    fi
    if ! grep -Fq "$message" "$WORK/failure.log"; then
        /bin/cat "$WORK/failure.log" >&2
        fail "Expected diagnostic: $message"
    fi
}
case "${1:-}" in
    ""|--version-only) ;;
    *) fail "Usage: test-release.sh [--version-only]" ;;
esac
if [[ "${1:-}" != --version-only ]]; then
(cd "$OUTPUT" && shasum -a 256 -c SHA256SUMS)
ditto -x -k "$ARCHIVE" "$WORK/extracted"
LICENSES="$WORK/extracted/McDiff.app/Contents/Resources/Licenses"
cmp LICENSE "$LICENSES/LICENSE"
cmp NOTICE "$LICENSES/NOTICE"
cmp .build/checkouts/Highlightr/LICENSE "$LICENSES/Highlightr-LICENSE"
cmp .build/checkouts/Highlightr/src/assets/highlighter/LICENSE "$LICENSES/highlight.js-LICENSE"
cmp .build/checkouts/swift-markdown/LICENSE.txt "$LICENSES/swift-markdown-LICENSE.txt"
cmp .build/checkouts/swift-markdown/NOTICE.txt "$LICENSES/swift-markdown-NOTICE.txt"
cmp .build/checkouts/swift-cmark/COPYING "$LICENSES/swift-cmark-COPYING"
sed -n '1,/^[[:space:]]*\*\//p' .build/checkouts/Highlightr/src/assets/highlighter/highlight.min.js > "$WORK/js-notice"
cmp "$WORK/js-notice" "$LICENSES/highlight.js-NOTICE"
cmp Sources/McDiff/Resources/Lucide/LICENSE "$WORK/extracted/McDiff.app/Contents/Resources/McDiff_McDiff.bundle/Contents/Resources/Resources/Lucide/LICENSE"
codesign --verify --deep --strict "$WORK/extracted/McDiff.app"
for ARCH in arm64 x86_64; do
    lipo "$WORK/extracted/McDiff.app/Contents/MacOS/McDiff" -verify_arch "$ARCH"
done
expect_failure "refusing to overwrite" bash scripts/package-release.sh "$WORK/extracted/McDiff.app" "$OUTPUT"
expect_failure "App not found" bash scripts/package-release.sh "$WORK/missing.app" "$WORK/output"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 999.999.999" "$WORK/extracted/McDiff.app/Contents/Info.plist"
expect_failure "CFBundleVersion does not match VERSION" bash scripts/package-release.sh "$WORK/extracted/McDiff.app" "$WORK/output"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$WORK/extracted/McDiff.app/Contents/Info.plist"
THIN_BINARY="$WORK/extracted/McDiff.app/Contents/MacOS/McDiff"
lipo "$THIN_BINARY" -thin arm64 -output "$WORK/thin"
mv "$WORK/thin" "$THIN_BINARY"
codesign --force --deep --sign - "$WORK/extracted/McDiff.app"
expect_failure "x86_64" bash scripts/package-release.sh "$WORK/extracted/McDiff.app" "$WORK/output"
git init -q "$WORK/tap"
ruby scripts/update-tap.rb "$ARCHIVE" "$WORK/tap"
ruby -c "$WORK/tap/Casks/mcdiff.rb"
# Evaluate the generated Ruby through a minimal Cask DSL to check its actual values.
ruby - "$WORK/tap/Casks/mcdiff.rb" "$VERSION" "$ARCHIVE" <<'RUBY'
require "digest"
class Cask
  attr_reader :fields
  def initialize
    @fields = {}
  end
  %i[version sha256 url name desc homepage depends_on app].each do |field|
    define_method(field) do |*args|
      return @fields.fetch(field) if args.empty?
      @fields[field] = args.first
    end
  end
end
def cask(name, &block)
  raise "Wrong cask name" unless name == "mcdiff"
  $cask = Cask.new
  $cask.instance_eval(&block)
end
load ARGV.fetch(0)
version = ARGV.fetch(1)
archive = ARGV.fetch(2)
raise "Wrong version" unless $cask.fields[:version] == version
raise "Wrong SHA256" unless $cask.fields[:sha256] == Digest::SHA256.file(archive).hexdigest
raise "Wrong URL" unless $cask.fields[:url] == "https://github.com/Nek-12/mcdiff/releases/download/v#{version}/McDiff-#{version}-macos-universal.zip"
raise "Wrong app" unless $cask.fields[:app] == "McDiff.app"
raise "Wrong minimum OS" unless $cask.fields[:depends_on] == {macos: ">= :tahoe"}
RUBY
expect_failure "Expected McDiff-" ruby scripts/update-tap.rb "$WORK/other.zip" "$WORK/tap"
expect_failure "Tap checkout not found" ruby scripts/update-tap.rb "$ARCHIVE" "$WORK/no-tap"
fi
mkdir -p "$WORK/version/scripts"
cp scripts/version.sh "$WORK/version/scripts/"
for invalid in "" 1.2 01.2.3 v1.2.3 1.2.3-rc.1; do
    echo "$invalid" > "$WORK/version/VERSION"
    expect_failure "VERSION must contain" bash "$WORK/version/scripts/version.sh"
done
cp scripts/next-version.sh "$WORK/version/scripts/"
git init -q "$WORK/version"
git -C "$WORK/version" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm initial
echo '[]' > "$WORK/releases.json"
echo 0.1.0 > "$WORK/version/VERSION"
bash "$WORK/version/scripts/next-version.sh" "$WORK/releases.json" > "$WORK/next-version"
grep -Fxq version=0.1.0 "$WORK/next-version" || fail "First release must retain VERSION"
echo '[{"tag_name":"v0.1.0","draft":false},{"tag_name":"v0.1.1","draft":false}]' > "$WORK/releases.json"
bash "$WORK/version/scripts/next-version.sh" "$WORK/releases.json" > "$WORK/next-version"
grep -Fxq version=0.1.2 "$WORK/next-version" || fail "Published versions must advance patch"
echo 0.2.0 > "$WORK/version/VERSION"
bash "$WORK/version/scripts/next-version.sh" "$WORK/releases.json" > "$WORK/next-version"
grep -Fxq version=0.2.0 "$WORK/next-version" || fail "Explicit minor version must be retained"
echo '[{"tag_name":"v0.2.0","draft":true}]' > "$WORK/releases.json"
expect_failure "Draft v0.2.0 already exists" bash "$WORK/version/scripts/next-version.sh" "$WORK/releases.json"
echo '[]' > "$WORK/releases.json"
git -C "$WORK/version" -c tag.gpgsign=false tag v0.2.0
expect_failure "exists without a published release" bash "$WORK/version/scripts/next-version.sh" "$WORK/releases.json"
echo 'not JSON' > "$WORK/releases.json"
expect_failure "parse error" bash "$WORK/version/scripts/next-version.sh" "$WORK/releases.json"
echo "Release script checks passed."

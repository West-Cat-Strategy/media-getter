#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/media-getter-appcast-smoke.XXXXXX")"
APP_PATH="$TEST_ROOT/MediaGetter.app"
SPARKLE_BIN_DIR="$TEST_ROOT/sparkle/bin"
BUILD_ROOT="$TEST_ROOT/build"
RELEASE_NOTES_FILE="$TEST_ROOT/release-notes.md"
APPCAST_PATH="$BUILD_ROOT/dist/appcast.xml"
ZIP_PATH="$BUILD_ROOT/dist/MediaGetter.zip"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$APP_PATH/Contents" "$SPARKLE_BIN_DIR"

cat >"$APP_PATH/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>0.2.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0.0</string>
</dict>
</plist>
EOF

cat >"$RELEASE_NOTES_FILE" <<'EOF'
- Smoke test release notes
EOF

cat >"$SPARKLE_BIN_DIR/sign_update" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${@: -1}"

if [[ "$target" == *.xml ]]; then
  cat >>"$target" <<'SIGNATURE'
<!-- sparkle-signatures:
edSignature: TEST_FEED_SIGNATURE
length: 123
-->
SIGNATURE
else
  printf 'sparkle:edSignature="TEST_ARCHIVE_SIGNATURE" length="123456"\n'
fi
EOF

chmod +x "$SPARKLE_BIN_DIR/sign_update"

APP_PATH="$APP_PATH" \
SPARKLE_BIN_DIR="$SPARKLE_BIN_DIR" \
BUILD_ROOT="$BUILD_ROOT" \
TAG_NAME="v0.2.0" \
RELEASE_NOTES_FILE="$RELEASE_NOTES_FILE" \
DOWNLOAD_URL="https://example.com/MediaGetter.zip" \
RELEASE_URL="https://github.com/West-Cat-Strategy/media-getter/releases/tag/v0.2.0" \
HARDWARE_REQUIREMENTS="arm64" \
"$ROOT_DIR/script/generate_sparkle_appcast.sh"

[[ -f "$ZIP_PATH" ]]
[[ -f "$APPCAST_PATH" ]]

grep -q "<title>Version 0.2.0</title>" "$APPCAST_PATH"
grep -q "<sparkle:version>0.2.0</sparkle:version>" "$APPCAST_PATH"
grep -q "<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>" "$APPCAST_PATH"
grep -q "<sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>" "$APPCAST_PATH"
grep -q "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>" "$APPCAST_PATH"
grep -q 'https://example.com/MediaGetter.zip' "$APPCAST_PATH"
grep -q 'TEST_ARCHIVE_SIGNATURE' "$APPCAST_PATH"
grep -q 'TEST_FEED_SIGNATURE' "$APPCAST_PATH"
grep -q 'sparkle:os="macos"' "$APPCAST_PATH"
grep -q 'Smoke test release notes' "$APPCAST_PATH"

echo "Appcast smoke test passed."

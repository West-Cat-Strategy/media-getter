#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/media-getter-dmg-smoke.XXXXXX")"
APP_PATH="$TEST_ROOT/MediaGetter.app"
DMG_PATH="$TEST_ROOT/MediaGetter.dmg"
MOUNT_POINT="$TEST_ROOT/mount"

cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$APP_PATH/Contents/MacOS"

cat >"$APP_PATH/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MediaGetter</string>
  <key>CFBundleIdentifier</key>
  <string>com.bryan.mediagetter.test</string>
  <key>CFBundleName</key>
  <string>MediaGetter</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
EOF

cat >"$APP_PATH/Contents/MacOS/MediaGetter" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$APP_PATH/Contents/MacOS/MediaGetter"

APP_PATH="$APP_PATH" \
DMG_PATH="$DMG_PATH" \
"$ROOT_DIR/script/build_dmg.sh"

[[ -f "$DMG_PATH" ]]

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

[[ -d "$MOUNT_POINT/MediaGetter.app" ]]
[[ -e "$MOUNT_POINT/Applications" ]]
[[ ! -L "$MOUNT_POINT/Applications" ]]

echo "DMG smoke test passed."

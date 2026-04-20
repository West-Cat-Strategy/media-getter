#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MediaGetter}"
SCHEME="${SCHEME:-$APP_NAME}"
PROJECT_SPEC="${PROJECT_SPEC:-$ROOT_DIR/project.yml}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/MediaGetter.xcodeproj}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_ROOT/${APP_NAME}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_ROOT/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$BUILD_ROOT/ExportOptions.plist}"
EXPORTED_APP_PATH_FILE="${EXPORTED_APP_PATH_FILE:-$BUILD_ROOT/exported-app-path.txt}"
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_DEVELOPER_ID_APPLICATION_IDENTITY="${APPLE_DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application}"

if [[ -z "$XCODEGEN_BIN" ]]; then
  echo "error: xcodegen is required to generate $PROJECT_PATH before archiving." >&2
  exit 1
fi

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$BUILD_ROOT" "$EXPORT_PATH"

"$XCODEGEN_BIN" generate --spec "$PROJECT_SPEC"

cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>${APPLE_DEVELOPER_ID_APPLICATION_IDENTITY}</string>
  <key>stripSwiftSymbols</key>
  <true/>
EOF

if [[ -n "$APPLE_TEAM_ID" ]]; then
  cat >>"$EXPORT_OPTIONS_PLIST" <<EOF
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
EOF
fi

cat >>"$EXPORT_OPTIONS_PLIST" <<'EOF'
</dict>
</plist>
EOF

archive_args=(
  xcodebuild archive
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  -destination "generic/platform=macOS"
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
)

if [[ -n "$APPLE_TEAM_ID" ]]; then
  archive_args+=("DEVELOPMENT_TEAM=$APPLE_TEAM_ID")
fi

"${archive_args[@]}"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -type d -name '*.app' -print -quit)"
fi

if [[ -z "${APP_PATH:-}" ]] || [[ ! -d "$APP_PATH" ]]; then
  echo "error: failed to locate exported app bundle in $EXPORT_PATH" >&2
  exit 1
fi

printf '%s\n' "$APP_PATH" >"$EXPORTED_APP_PATH_FILE"
echo "Exported app bundle: $APP_PATH"

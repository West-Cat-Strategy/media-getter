#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MediaGetter}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/release}"
EXPORTED_APP_PATH_FILE="${EXPORTED_APP_PATH_FILE:-$BUILD_ROOT/exported-app-path.txt}"
APP_PATH="${1:-${APP_PATH:-}}"
VOLUME_NAME="${VOLUME_NAME:-MediaGetter}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/${APP_NAME}.dmg}"

if [[ -z "$APP_PATH" ]] && [[ -f "$EXPORTED_APP_PATH_FILE" ]]; then
  APP_PATH="$(<"$EXPORTED_APP_PATH_FILE")"
fi

if [[ -z "$APP_PATH" ]]; then
  echo "error: missing app path. Run script/export_release_bundle.sh first or pass APP_PATH/script/build_dmg.sh [APP_PATH]." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app bundle at $APP_PATH" >&2
  exit 1
fi

if [[ "${APP_PATH##*.}" != "app" ]]; then
  echo "error: expected a .app bundle, got $APP_PATH" >&2
  exit 1
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/media-getter-dmg.XXXXXX")"
STAGING_DIR="$STAGING_ROOT/staging"
TEMP_DMG="$STAGING_ROOT/${APP_NAME}.dmg"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"

APP_BUNDLE_NAME="$(basename "$APP_PATH")"
ditto "$APP_PATH" "$STAGING_DIR/$APP_BUNDLE_NAME"

osascript \
  -e 'set targetFolder to POSIX file "/Applications"' \
  -e "set destinationFolder to POSIX file \"$STAGING_DIR\"" \
  -e 'tell application "Finder" to make new alias file to targetFolder at destinationFolder' \
  >/dev/null

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$TEMP_DMG" \
  >/dev/null

mv "$TEMP_DMG" "$DMG_PATH"

echo "DMG created: $DMG_PATH"

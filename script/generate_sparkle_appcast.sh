#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MediaGetter}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/release}"
DIST_PATH="${DIST_PATH:-$BUILD_ROOT/dist}"
EXPORTED_APP_PATH_FILE="${EXPORTED_APP_PATH_FILE:-$BUILD_ROOT/exported-app-path.txt}"
APP_PATH="${1:-${APP_PATH:-}}"
SPARKLE_BIN_DIR="${2:-${SPARKLE_BIN_DIR:-}}"
TAG_NAME="${TAG_NAME:-}"
REPO_SLUG="${REPO_SLUG:-West-Cat-Strategy/media-getter}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-$BUILD_ROOT/release-notes.md}"
RELEASE_PUBLISHED_AT="${RELEASE_PUBLISHED_AT:-}"
RELEASE_URL="${RELEASE_URL:-https://github.com/${REPO_SLUG}/releases/tag/${TAG_NAME}}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/${REPO_SLUG}/releases/download/${TAG_NAME}/${APP_NAME}.zip}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-media-getter}"
ZIP_PATH="${ZIP_PATH:-$DIST_PATH/${APP_NAME}.zip}"
APPCAST_PATH="${APPCAST_PATH:-$DIST_PATH/appcast.xml}"
ZIP_PATH_FILE="${ZIP_PATH_FILE:-$BUILD_ROOT/zip-path.txt}"
APPCAST_PATH_FILE="${APPCAST_PATH_FILE:-$BUILD_ROOT/appcast-path.txt}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-}"
HARDWARE_REQUIREMENTS="${HARDWARE_REQUIREMENTS:-}"

if [[ -z "$APP_PATH" ]] && [[ -f "$EXPORTED_APP_PATH_FILE" ]]; then
  APP_PATH="$(<"$EXPORTED_APP_PATH_FILE")"
fi

if [[ -z "$APP_PATH" ]]; then
  echo "error: missing app path. Pass it as the first argument or APP_PATH." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app bundle at $APP_PATH" >&2
  exit 1
fi

if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  echo "error: missing Sparkle bin directory. Pass it as the second argument or SPARKLE_BIN_DIR." >&2
  exit 1
fi

if [[ -z "$TAG_NAME" ]]; then
  echo "error: missing tag name. Set TAG_NAME before generating the appcast." >&2
  exit 1
fi

SIGN_UPDATE_BIN="$SPARKLE_BIN_DIR/sign_update"
if [[ ! -x "$SIGN_UPDATE_BIN" ]]; then
  echo "error: Sparkle sign_update tool is not executable at $SIGN_UPDATE_BIN" >&2
  exit 1
fi

mkdir -p "$DIST_PATH"
rm -f "$ZIP_PATH" "$APPCAST_PATH"

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

ARCHIVE_SIGNATURE="$("$SIGN_UPDATE_BIN" --account "$SPARKLE_KEY_ACCOUNT" "$ZIP_PATH")"
ARCHIVE_LENGTH="$(printf '%s\n' "$ARCHIVE_SIGNATURE" | sed -n 's/.*length="\([0-9][0-9]*\)".*/\1/p')"
ARCHIVE_ED_SIGNATURE="$(printf '%s\n' "$ARCHIVE_SIGNATURE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"

if [[ -z "$ARCHIVE_LENGTH" || -z "$ARCHIVE_ED_SIGNATURE" ]]; then
  echo "error: failed to parse Sparkle archive signature output." >&2
  exit 1
fi

VERSION_STRING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || printf '%s\n' "$APP_NAME")"

if [[ -z "$MINIMUM_SYSTEM_VERSION" ]]; then
  MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
fi

if [[ -z "$HARDWARE_REQUIREMENTS" ]]; then
  EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
  if [[ -f "$EXECUTABLE_PATH" ]]; then
    ARCH_INFO="$(/usr/bin/lipo -info "$EXECUTABLE_PATH" 2>/dev/null || /usr/bin/file -b "$EXECUTABLE_PATH" 2>/dev/null || true)"
    if [[ "$ARCH_INFO" == *"arm64"* ]] && [[ "$ARCH_INFO" != *"x86_64"* ]]; then
      HARDWARE_REQUIREMENTS="arm64"
    fi
  fi
fi

MINIMUM_SYSTEM_VERSION_XML=""
if [[ -n "$MINIMUM_SYSTEM_VERSION" ]]; then
  MINIMUM_SYSTEM_VERSION_XML="      <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>"
fi

HARDWARE_REQUIREMENTS_XML=""
if [[ -n "$HARDWARE_REQUIREMENTS" ]]; then
  HARDWARE_REQUIREMENTS_XML="      <sparkle:hardwareRequirements>${HARDWARE_REQUIREMENTS}</sparkle:hardwareRequirements>"
fi

PUB_DATE="$(
  python3 - "$RELEASE_PUBLISHED_AT" <<'PY'
from datetime import datetime, timezone
from email.utils import format_datetime
import sys

raw = sys.argv[1]
if raw:
    dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
else:
    dt = datetime.now(timezone.utc)
print(format_datetime(dt))
PY
)"

RELEASE_NOTES_HTML="$(
  python3 - "$RELEASE_NOTES_FILE" <<'PY'
import html
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if path.is_file():
    body = path.read_text(encoding="utf-8").strip()
else:
    body = ""

if not body:
    print("<p>No release notes were provided for this release.</p>")
    raise SystemExit(0)

escaped = html.escape(body).replace("]]>", "]]]]><![CDATA[>")
print('<pre style="white-space: pre-wrap; font: -apple-system-body;">')
print(escaped)
print("</pre>")
PY
)"

cat >"$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME} Updates</title>
    <link>${RELEASE_URL}</link>
    <description>Latest ${APP_NAME} release feed.</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION_STRING}</title>
      <link>${RELEASE_URL}</link>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION_STRING}</sparkle:shortVersionString>
${MINIMUM_SYSTEM_VERSION_XML}
${HARDWARE_REQUIREMENTS_XML}
      <pubDate>${PUB_DATE}</pubDate>
      <description><![CDATA[
${RELEASE_NOTES_HTML}
      ]]></description>
      <enclosure
        url="${DOWNLOAD_URL}"
        type="application/octet-stream"
        length="${ARCHIVE_LENGTH}"
        sparkle:edSignature="${ARCHIVE_ED_SIGNATURE}"
        sparkle:os="macos" />
    </item>
  </channel>
</rss>
EOF

"$SIGN_UPDATE_BIN" --account "$SPARKLE_KEY_ACCOUNT" "$APPCAST_PATH" >/dev/null

printf '%s\n' "$ZIP_PATH" >"$ZIP_PATH_FILE"
printf '%s\n' "$APPCAST_PATH" >"$APPCAST_PATH_FILE"

echo "Sparkle archive: $ZIP_PATH"
echo "Sparkle appcast: $APPCAST_PATH"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MediaGetter}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/release}"
EXPORTED_APP_PATH_FILE="${EXPORTED_APP_PATH_FILE:-$BUILD_ROOT/exported-app-path.txt}"
APP_PATH="${1:-${APP_PATH:-}}"
NOTARY_API_KEY_PATH="${NOTARY_API_KEY_PATH:-}"
APPLE_NOTARY_API_KEY_ID="${APPLE_NOTARY_API_KEY_ID:-}"
APPLE_NOTARY_API_ISSUER_ID="${APPLE_NOTARY_API_ISSUER_ID:-}"
NOTARY_SUBMISSION_ZIP="${NOTARY_SUBMISSION_ZIP:-$BUILD_ROOT/notary/${APP_NAME}-notary.zip}"

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

if [[ -z "$NOTARY_API_KEY_PATH" || -z "$APPLE_NOTARY_API_KEY_ID" || -z "$APPLE_NOTARY_API_ISSUER_ID" ]]; then
  echo "error: notarization requires NOTARY_API_KEY_PATH, APPLE_NOTARY_API_KEY_ID, and APPLE_NOTARY_API_ISSUER_ID." >&2
  exit 1
fi

mkdir -p "$(dirname "$NOTARY_SUBMISSION_ZIP")"
rm -f "$NOTARY_SUBMISSION_ZIP"

ditto -c -k --keepParent "$APP_PATH" "$NOTARY_SUBMISSION_ZIP"

xcrun notarytool submit "$NOTARY_SUBMISSION_ZIP" \
  --key "$NOTARY_API_KEY_PATH" \
  --key-id "$APPLE_NOTARY_API_KEY_ID" \
  --issuer "$APPLE_NOTARY_API_ISSUER_ID" \
  --wait

xcrun stapler staple -v "$APP_PATH"
spctl -a -vv "$APP_PATH"

echo "Notarized app bundle: $APP_PATH"

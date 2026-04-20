#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MediaGetter"
BUNDLE_ID="com.bryan.mediagetter"
MIN_SYSTEM_VERSION="14.0"
ARCH="arm64"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
PROJECT_PATH="$ROOT_DIR/MediaGetter.xcodeproj"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ -z "$XCODEGEN_BIN" ]]; then
  echo "error: xcodegen is required to generate $PROJECT_PATH before building." >&2
  exit 1
fi

"$XCODEGEN_BIN" generate --spec "$ROOT_DIR/project.yml"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  -destination "platform=macOS,arch=${ARCH}" \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET="$MIN_SYSTEM_VERSION" \
  build >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

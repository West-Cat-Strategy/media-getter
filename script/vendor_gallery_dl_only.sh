#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/build/vendor-media"
ARTIFACTS_DIR="$WORK_DIR/artifacts"
DOWNLOADS_DIR="$WORK_DIR/downloads"
VENDOR_TOOLS_DIR="$ROOT_DIR/Vendor/Tools"
VENDOR_MODELS_DIR="$ROOT_DIR/Vendor/Models"

mkdir -p "$WORK_DIR" "$ARTIFACTS_DIR" "$DOWNLOADS_DIR" "$VENDOR_TOOLS_DIR" "$VENDOR_MODELS_DIR"

download_file() {
  local url="$1"
  local output_path="$2"
  curl -L --fail --retry 3 --retry-delay 2 "$url" -o "$output_path"
}

assert_arm64_binary() {
  local tool_path="$1"
  local description
  description="$(/usr/bin/file -b "$tool_path")"
  if [[ "$description" == *"universal binary"* ]] || [[ "$description" != *"arm64"* ]]; then
    echo "error: expected an arm64-only binary at $tool_path. Found: $description" >&2
    exit 1
  fi
}

assert_self_contained_binary() {
  local tool_path="$1"
  local dependency
  while read -r dependency _; do
    [[ -z "$dependency" ]] && continue
    case "$dependency" in
      /System/*|/usr/lib/*|@executable_path/*|@loader_path/*|@rpath/*)
        ;;
      *)
        echo "error: binary $tool_path links an external dependency: $dependency" >&2
        exit 1
        ;;
    esac
  done < <(/usr/bin/otool -L "$tool_path" | tail -n +2 | sed 's/^[[:space:]]*//')
}

echo "Downloading gallery-dl..."
archive_path="$DOWNLOADS_DIR/gallery-dl_macos"
thin_path="$ARTIFACTS_DIR/gallery-dl"

download_file \
  "https://github.com/gdl-org/builds/releases/latest/download/gallery-dl_macos" \
  "$archive_path"

echo "Checking if thinning is needed..."
description="$(/usr/bin/file -b "$archive_path")"
if [[ "$description" == *"universal binary"* ]]; then
    echo "Thinning to arm64..."
    /usr/bin/lipo "$archive_path" -thin arm64 -output "$thin_path"
else
    echo "Already thinned or non-universal, copying..."
    cp -f "$archive_path" "$thin_path"
fi

chmod +x "$thin_path"
assert_arm64_binary "$thin_path"
assert_self_contained_binary "$thin_path"

echo "Copying to Vendor/Tools..."
cp -f "$thin_path" "$VENDOR_TOOLS_DIR/gallery-dl"

echo "Checking for missing whisper model..."
MODEL_PATH="$VENDOR_MODELS_DIR/ggml-base.en.bin"
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Downloading ggml-base.en.bin..."
    download_file \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
      "$MODEL_PATH"
fi

echo "Done! gallery-dl and models are ready."

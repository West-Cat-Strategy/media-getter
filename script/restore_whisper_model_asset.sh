#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_MODELS_DIR="$ROOT_DIR/Vendor/Models"
MODEL_PATH="$VENDOR_MODELS_DIR/ggml-base.en.bin"
MODEL_URL="${WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin}"

mkdir -p "$VENDOR_MODELS_DIR"

if [[ -f "$MODEL_PATH" ]]; then
  echo "Whisper base.en model already exists at $MODEL_PATH"
  exit 0
fi

echo "Restoring ignored Whisper base.en model asset..."
curl -L --fail --retry 3 --retry-delay 2 "$MODEL_URL" -o "$MODEL_PATH"
test -s "$MODEL_PATH"

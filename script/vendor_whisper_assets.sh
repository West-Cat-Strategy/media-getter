#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "vendor_whisper_assets.sh now delegates to vendor_media_tools.sh for the full Apple Silicon toolchain."
exec "$ROOT_DIR/script/vendor_media_tools.sh"

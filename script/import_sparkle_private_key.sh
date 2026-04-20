#!/usr/bin/env bash
set -euo pipefail

SPARKLE_BIN_DIR="${1:-${SPARKLE_BIN_DIR:-}}"
SPARKLE_PRIVATE_KEY_FILE="${2:-${SPARKLE_PRIVATE_KEY_FILE:-}}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-media-getter}"

if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  echo "error: missing Sparkle bin directory. Pass it as the first argument or SPARKLE_BIN_DIR." >&2
  exit 1
fi

if [[ -z "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  echo "error: missing Sparkle private key file. Pass it as the second argument or SPARKLE_PRIVATE_KEY_FILE." >&2
  exit 1
fi

GENERATE_KEYS_BIN="$SPARKLE_BIN_DIR/generate_keys"

if [[ ! -x "$GENERATE_KEYS_BIN" ]]; then
  echo "error: Sparkle generate_keys tool is not executable at $GENERATE_KEYS_BIN" >&2
  exit 1
fi

"$GENERATE_KEYS_BIN" --account "$SPARKLE_KEY_ACCOUNT" -f "$SPARKLE_PRIVATE_KEY_FILE"

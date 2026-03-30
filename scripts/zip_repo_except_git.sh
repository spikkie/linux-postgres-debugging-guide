#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-.}"
OUT_ZIP="${2:-}"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Source directory does not exist: $SRC_DIR" >&2
  exit 1
fi

SRC_DIR="$(cd "$SRC_DIR" && pwd)"

if [[ -z "$OUT_ZIP" ]]; then
  BASENAME="$(basename "$SRC_DIR")"
  PARENT="$(dirname "$SRC_DIR")"
  OUT_ZIP="$PARENT/${BASENAME}.zip"
fi

echo "Creating zip archive..."
echo "  Source: $SRC_DIR"
echo "  Output: $OUT_ZIP"
echo

(
  cd "$SRC_DIR"
  zip -r "$OUT_ZIP" .         -x ".git/*"         -x "*/.git/*"
)

echo
echo "Done: $OUT_ZIP"

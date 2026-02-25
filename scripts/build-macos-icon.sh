#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_PNG="${1:-$ROOT_DIR/assets/branding/deepcrate-logo-mark.png}"
OUT_ICNS="${2:-$ROOT_DIR/assets/branding/DeepCrate.icns}"
TMP_DIR="$ROOT_DIR/.iconbuild"
ICONSET_DIR="$TMP_DIR/DeepCrate.iconset"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd sips
require_cmd iconutil

if [[ ! -f "$SRC_PNG" ]]; then
  echo "Source PNG not found: $SRC_PNG" >&2
  exit 1
fi

rm -rf "$TMP_DIR"
mkdir -p "$ICONSET_DIR"
mkdir -p "$(dirname "$OUT_ICNS")"

resize_icon() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$SRC_PNG" --out "$ICONSET_DIR/$name" >/dev/null
}

resize_icon 16 icon_16x16.png
resize_icon 32 icon_16x16@2x.png
resize_icon 32 icon_32x32.png
resize_icon 64 icon_32x32@2x.png
resize_icon 128 icon_128x128.png
resize_icon 256 icon_128x128@2x.png
resize_icon 256 icon_256x256.png
resize_icon 512 icon_256x256@2x.png
resize_icon 512 icon_512x512.png
resize_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"
echo "Created $OUT_ICNS"

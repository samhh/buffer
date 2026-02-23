#!/usr/bin/env bash
set -euo pipefail

SRC_SVG="${1:-assets/icon/buffer-icon.svg}"
OUT_DIR="assets/icon"
ICONSET_DIR="$OUT_DIR/Buffer.iconset"
BASE_PNG="$OUT_DIR/buffer-icon-bg.png"
FINAL_PNG="$OUT_DIR/buffer-icon.svg.png"
ICNS_PATH="$OUT_DIR/Buffer.icns"

if [[ ! -f "$SRC_SVG" ]]; then
  echo "Missing source SVG: $SRC_SVG" >&2
  exit 1
fi

if ! command -v qlmanage >/dev/null 2>&1; then
  echo "qlmanage is required to rasterize SVG on macOS." >&2
  exit 1
fi

rm -rf "$ICONSET_DIR" "$ICNS_PATH"
mkdir -p "$OUT_DIR" "$ICONSET_DIR"

qlmanage -t -s 1024 -o "$OUT_DIR" "$SRC_SVG" >/dev/null
mv "$OUT_DIR/$(basename "$SRC_SVG").png" "$BASE_PNG"

CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clang-module-cache" \
swift scripts/render-sf-symbol-icon.swift "$BASE_PNG" "$FINAL_PNG" scribble >/dev/null

sips -z 16 16 "$FINAL_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$FINAL_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$FINAL_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$FINAL_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$FINAL_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$FINAL_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$FINAL_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$FINAL_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$FINAL_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$FINAL_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
echo "Generated $ICNS_PATH"

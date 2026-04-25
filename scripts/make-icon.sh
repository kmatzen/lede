#!/usr/bin/env bash
# Build Resources/AppIcon.icns from a single source PNG (icon.png at repo root).
#
# Apple wants 10 sizes paired @1x and @2x in an .iconset folder, then iconutil
# packs them into an .icns. We use sips (built into macOS) to resize.
set -euo pipefail

SRC="${1:-icon.png}"
OUT_DIR="Resources"
ICONSET="$OUT_DIR/AppIcon.iconset"
ICNS="$OUT_DIR/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
    echo "error: source icon $SRC not found" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Sizes Apple expects in an iconset.
declare -a sizes=(
    "16    icon_16x16.png"
    "32    icon_16x16@2x.png"
    "32    icon_32x32.png"
    "64    icon_32x32@2x.png"
    "128   icon_128x128.png"
    "256   icon_128x128@2x.png"
    "256   icon_256x256.png"
    "512   icon_256x256@2x.png"
    "512   icon_512x512.png"
    "1024  icon_512x512@2x.png"
)

for spec in "${sizes[@]}"; do
    size="${spec%% *}"
    name="${spec##* }"
    sips -s format png -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$ICNS"
echo "✓ Wrote $ICNS"

#!/usr/bin/env bash
#
# Draws the app icon and packs it into dist/AppIcon.icns.
#
#   scripts/make-icon.sh
#
# The artwork is Core Graphics, in scripts/make-icon.swift, and is drawn three
# ways: full detail at 256 and up, simplified at 64 and 128, and a separate
# high-contrast drawing at 32 and below. Small sizes are redrawn, never
# downscaled — a faithful reduction of the full artwork is a grey smudge.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/icon"
ICONSET="$ROOT/dist/AppIcon.iconset"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "drawing"
swift "$ROOT/scripts/make-icon.swift" "$OUT"

log "assembling iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# iconutil wants both scales of each point size; the @2x of one size is the
# pixel size above it, which is why the same file appears twice.
cp "$OUT/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$OUT/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$OUT/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$OUT/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$OUT/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$OUT/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$OUT/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$OUT/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$OUT/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$OUT/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

log "packing"
iconutil -c icns "$ICONSET" -o "$ROOT/dist/AppIcon.icns"
log "wrote $ROOT/dist/AppIcon.icns"

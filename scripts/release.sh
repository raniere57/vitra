#!/usr/bin/env bash
#
# Builds the distributable disk image.
#
#   scripts/release.sh
#
# Produces dist/Vitra-<version>.dmg containing a size-optimised, ad-hoc signed
# Vitra.app and an alias to /Applications. The image is not notarised — there is
# no Developer ID here — so the README documents the quarantine flag a downloader
# has to clear.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/.build/dmg"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$ROOT/dist/AppIcon.icns" ]] || die "no dist/AppIcon.icns — run scripts/make-icon.sh first"

# -Osize over -O: this is a terminal, not a compute kernel, and the hot paths
# that matter (the render loop, the vt feed) are dominated by libghostty and
# Metal rather than by Swift the optimiser could unroll. Dead stripping removes
# what the linker can prove nothing reaches.
log "release build"
VITRA_BUILD_FLAGS="-Xswiftc -Osize -Xlinker -dead_strip" "$ROOT/scripts/build-app.sh"

# The version comes from the app that was just built, not from whatever was in
# dist before it: reading it first shipped 0.1.1 in a disk image called 0.1.0.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/dist/Vitra.app/Contents/Info.plist")"
VOLUME="Vitra $VERSION"
DMG="$ROOT/dist/Vitra-$VERSION.dmg"

log "staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$ROOT/dist/Vitra.app" "$STAGE/Vitra.app"
ln -s /Applications "$STAGE/Applications"

swift "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background/background.png" >/dev/null
cp "$ROOT/dist/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true

# A read-write image first: the layout below is Finder moving real icons around
# in a real window, which cannot happen on a compressed one.
log "creating image"
rm -f "$DMG" "$ROOT/dist/rw.dmg"
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
  -format UDRW -ov "$ROOT/dist/rw.dmg" >/dev/null

MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$ROOT/dist/rw.dmg" | grep -o '/Volumes/.*$' | head -1)"
[[ -n "$MOUNT" ]] || die "could not mount the image"

log "arranging window"
# Finder is what stores icon positions, so this needs Automation permission the
# first time; if it is denied the image still works, it just opens as a list.
osascript <<APPLESCRIPT || printf 'note: Finder layout skipped (no Automation permission)\n'
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 840, 540}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 96
    set background picture of options to file ".background:background.png"
    set position of item "Vitra.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" >/dev/null

log "compressing"
hdiutil convert "$ROOT/dist/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$ROOT/dist/rw.dmg"
rm -rf "$STAGE"

log "wrote $DMG ($(du -sh "$DMG" | cut -f1))"

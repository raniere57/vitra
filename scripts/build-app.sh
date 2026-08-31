#!/usr/bin/env bash
#
# Builds Vitra.app from the SwiftPM release binary.
#
#   scripts/build-app.sh            build into dist/Vitra.app
#   scripts/build-app.sh --install  also copy into /Applications
#
# /Applications is writable by an admin user without sudo, and is where both
# Spotlight and LaunchServices expect to find an app.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/release"
APP="$ROOT/dist/Vitra.app"
VERSION="0.1.0"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

log "building release"
# VITRA_BUILD_FLAGS is how release.sh adds -Osize and dead stripping without
# a second copy of this script.
(cd "$ROOT" && swift build -c release --product VitraApp ${VITRA_BUILD_FLAGS:-})
[[ -x "$BUILD/VitraApp" ]] || die "release binary not found at $BUILD/VitraApp"

log "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD/VitraApp" "$APP/Contents/MacOS/Vitra"

# The CLI ships inside the bundle so it updates with the app; the README
# explains linking it onto PATH. It cannot live in Contents/MacOS beside the
# executable: the filesystem is case-insensitive, so `vitra` would overwrite
# `Vitra`.
mkdir -p "$APP/Contents/Helpers"
cp "$ROOT/scripts/vitra" "$APP/Contents/Helpers/vitra"
chmod +x "$APP/Contents/Helpers/vitra"

# SwiftPM resource bundles (default.metallib lives in one) are found through
# Bundle.main.resourceURL inside an app bundle.
for bundle in "$BUILD"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Vitra</string>
    <key>CFBundleDisplayName</key>     <string>Vitra</string>
    <key>CFBundleIdentifier</key>      <string>dev.vitra.Vitra</string>
    <key>CFBundleExecutable</key>      <string>Vitra</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSSupportsSuddenTermination</key>    <false/>
    <!-- Viewer of last resort: this is what lets "vitra open" hand any file to
         the running app. LSHandlerRank None keeps Vitra out of the running for
         becoming anything's default application. -->
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key>   <string>Any File</string>
        <key>CFBundleTypeRole</key>   <string>Viewer</string>
        <key>LSHandlerRank</key>      <string>None</string>
        <key>LSItemContentTypes</key> <array><string>public.item</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

[[ -f "$ROOT/dist/AppIcon.icns" ]] && cp "$ROOT/dist/AppIcon.icns" "$APP/Contents/Resources/"

# Ad-hoc signature. Without any signature at all, macOS refuses to launch an
# arm64 binary outright rather than merely warning about it.
log "signing ad-hoc"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true

log "built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/Vitra.app"
  cp -R "$APP" "$DEST/Vitra.app"
  # Spotlight indexes on its own schedule; nudge it so the app is findable now.
  mdimport "$DEST/Vitra.app" 2>/dev/null || true
  log "installed to $DEST/Vitra.app"
fi

#!/usr/bin/env bash
#
# Fetches and builds libghostty-vt at a pinned commit, then installs the static
# library and headers into vendor/ for SwiftPM to link against.
#
# The pinned commit is recorded in docs/DEPENDENCIES.md. libghostty-vt's C API is
# explicitly documented as unstable, so this must never track a moving branch.
#
# Usage: scripts/vendor-ghostty-vt.sh [--force]

set -euo pipefail

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_COMMIT="f64f4aca2c29b554d111b36c3d946a9bddd159ff"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/ghostty-src"
PREFIX="$ROOT/vendor/ghostty-vt"
HEADERS_DEST="$ROOT/Sources/CGhosttyVT/include"
STAMP="$PREFIX/.vendored-commit"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${1:-}" == "--force" ]] && rm -rf "$PREFIX" "$HEADERS_DEST/ghostty"

command -v zig >/dev/null || die "zig not found on PATH. Install with: brew install zig"

# Ghostty pins a minimum Zig version in build.zig.zon; a mismatch fails deep in
# the build with an unhelpful message, so check it up front.
ZIG_VERSION="$(zig version)"
log "zig $ZIG_VERSION"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$GHOSTTY_COMMIT" ]]; then
  log "already vendored at $GHOSTTY_COMMIT (pass --force to rebuild)"
  exit 0
fi

# Fetch only the pinned commit rather than cloning the full history.
if [[ ! -d "$SRC/.git" ]]; then
  log "fetching ghostty @ ${GHOSTTY_COMMIT:0:12}"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$GHOSTTY_REPO" 2>/dev/null || true
fi
git -C "$SRC" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD

# -Demit-lib-vt switches Ghostty's build to a libghostty-vt-only configuration:
# no xcframework, no macOS app, no docs. ReleaseFast matters a lot here — debug
# builds of Ghostty are very slow and memory-hungry.
log "building libghostty-vt (ReleaseFast)"
(cd "$SRC" && zig build \
  -Demit-lib-vt \
  -Doptimize=ReleaseFast \
  --prefix "$PREFIX")

# Headers live next to the Swift target so SwiftPM's include path stays simple
# and `import CGhosttyVT` works without unsafe include flags.
log "installing headers into Sources/CGhosttyVT/include"
rm -rf "$HEADERS_DEST/ghostty"
mkdir -p "$HEADERS_DEST"
cp -R "$PREFIX/include/ghostty" "$HEADERS_DEST/ghostty"

STATIC_LIB="$(find "$PREFIX/lib" -name 'libghostty-vt*.a' | head -1)"
[[ -n "$STATIC_LIB" ]] || die "no static libghostty-vt found under $PREFIX/lib"

echo "$GHOSTTY_COMMIT" > "$STAMP"

log "done"
printf '    static lib: %s (%s)\n' "$STATIC_LIB" "$(du -h "$STATIC_LIB" | cut -f1)"
printf '    headers:    %s\n' "$HEADERS_DEST/ghostty"

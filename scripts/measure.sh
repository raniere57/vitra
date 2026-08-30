#!/usr/bin/env bash
#
# Memory and CPU measurement for Vitra. Every performance number in a phase
# report comes from here, not from an estimate.
#
#   scripts/measure.sh run  -- <command>   peak RSS of a command that exits
#   scripts/measure.sh live <pid|name>     footprint + CPU of a running process
#   scripts/measure.sh load                generate the 100 MB load fixture
#
# The canonical memory metric is phys_footprint, the number macOS itself uses
# for jetsam and shows in Activity Monitor. RSS is reported alongside it because
# it is the more familiar number, but it counts shared system pages the app does
# not really spend.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/.build/fixtures/load-100mb.txt"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

human() { awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1048576 }'; }

make_fixture() {
  [[ -f "$FIXTURE" ]] && { echo "$FIXTURE"; return; }
  mkdir -p "$(dirname "$FIXTURE")"
  # Printable text with realistic line lengths, not random bytes: the VT parser's
  # cost depends on how many cells and line breaks it has to process.
  # `yes` is killed by SIGPIPE once head has enough, which pipefail would
  # otherwise report as a failure.
  { yes 'the quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuvwxyz' || true; } \
    | head -c 104857600 > "$FIXTURE"
  echo "$FIXTURE"
}

case "${1:-}" in
  load)
    make_fixture
    ;;

  run)
    shift
    [[ "${1:-}" == "--" ]] && shift
    [[ $# -gt 0 ]] || die "usage: measure.sh run -- <command>"
    # /usr/bin/time -l reports peak RSS for a process that runs to completion,
    # which is exactly the "under load" number without attaching a profiler.
    /usr/bin/time -l "$@" 2>&1 >/dev/null \
      | awk '/maximum resident set size/ { printf "peak RSS: %.1f MB\n", $1 / 1048576 }
             /real/                      { printf "wall: %s s  user: %s s  sys: %s s\n", $1, $3, $5 }'
    ;;

  live)
    target="${2:-}"
    [[ -n "$target" ]] || die "usage: measure.sh live <pid|process-name>"
    if [[ "$target" =~ ^[0-9]+$ ]]; then pid="$target"; else pid="$(pgrep -x "$target" | head -1)"; fi
    [[ -n "${pid:-}" ]] || die "no process matching '$target'"

    printf 'pid %s\n' "$pid"

    # phys_footprint is the number macOS uses for jetsam and shows in Activity
    # Monitor. RSS is reported too because it is the familiar number, but it
    # counts shared framework pages the app does not really spend.
    footprint -p "$pid" --noCategories 2>/dev/null \
      | awk '/phys_footprint:/ { printf "phys_footprint: %s %s\n", $2, $3 }
             /phys_footprint_peak:/ { printf "peak:           %s %s\n", $2, $3 }'
    ps -o rss=,vsz= -p "$pid" | awk '{ printf "RSS:            %.1f MB\n", $1 / 1024 }'

    # 11 samples, first discarded: top reports a meaningless cumulative value on
    # its first pass.
    printf 'CPU (10x1s):    '
    top -l 11 -s 1 -pid "$pid" -stats cpu 2>/dev/null \
      | awk '/^[0-9.]+$/ { n++; if (n > 1) { sum += $1; c++ } } END { printf "%.2f%% avg\n", (c ? sum / c : 0) }'

    # WebKit runs in XPC services owned by launchd, not as our children, so they
    # cannot be attributed by process tree. Phase 3 measures them as a delta
    # around opening and closing the browser panel instead.
    children="$(pgrep -P "$pid" 2>/dev/null || true)"
    if [[ -n "$children" ]]; then
      printf 'child processes: %s\n' "$(echo "$children" | tr '\n' ' ')"
    fi
    ;;

  *)
    die "usage: measure.sh {run -- <command> | live <pid|name> | load}"
    ;;
esac

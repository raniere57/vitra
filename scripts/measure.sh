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
    footprint -j "$pid" 2>/dev/null | tail -5 || printf '  (footprint needs no privileges but may be unavailable)\n'
    ps -o rss=,vsz= -p "$pid" | awk '{ printf "RSS: %.1f MB   VSZ: %.1f MB\n", $1 / 1024, $2 / 1024 }'

    # 10 one-second samples; the first is discarded because top reports a
    # meaningless cumulative value on its first pass.
    printf 'CPU (10x1s): '
    top -l 11 -s 1 -pid "$pid" -stats cpu 2>/dev/null \
      | awk '/^[0-9.]+$/ { n++; if (n > 1) { sum += $1; c++ } } END { printf "%.2f%% avg\n", (c ? sum / c : 0) }'

    # WebKit runs out of process; the app's own footprint never includes it.
    webkit="$(pgrep -f 'com.apple.WebKit' || true)"
    if [[ -n "$webkit" ]]; then
      printf 'WebKit helper processes: %s\n' "$(echo "$webkit" | tr '\n' ' ')"
      echo "$webkit" | xargs -I{} ps -o rss=,comm= -p {} \
        | awk '{ rss += $1; printf "  %.1f MB  %s\n", $1 / 1024, $2 } END { printf "  total: %.1f MB\n", rss / 1024 }'
    else
      printf 'WebKit helper processes: none\n'
    fi
    ;;

  *)
    die "usage: measure.sh {run -- <command> | live <pid|name> | load}"
    ;;
esac

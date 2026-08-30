# Measurements

Every number here comes from `scripts/measure.sh`, never from an estimate. Each
phase appends its own section; nothing is edited in place, so regressions stay
visible.

Machine: MacBook Air M1, 8 GB, macOS 26.5.2, arm64.

## Budgets

| Budget | Target | Metric |
|---|---|---|
| Memory, normal use | <= 150 MB | `phys_footprint` of the `Vitra` process |
| Memory, WebKit open | reported separately | sum over `com.apple.WebKit.*` children |
| CPU, focused idle | < 0.3% | 10x1s `top` samples |
| CPU, unfocused idle | 0.0% | 10x1s `top` samples |

WebKit runs out of process, so the app's own footprint never includes it. Both
numbers are always reported; the app-process number is the contractual one.

## Phase 0 - core VT, headless

Commit: initial. Binary: `.build/release/vitra-spike` (no window, no renderer).

| Scenario | Peak RSS | Wall | Notes |
|---|---|---|---|
| `echo hi` | 7.1 MB | 0.41 s | process floor: Swift runtime + libghostty-vt |
| `cat` 100 MB fixture | 7.9 MB | 0.69 s | 101.2 MB read in 103999 chunks, 135 MB/s |

Reproduce:

```bash
scripts/measure.sh load
scripts/measure.sh run -- .build/release/vitra-spike /bin/echo hi
VITRA_SPIKE_TIMEOUT=120 scripts/measure.sh run -- .build/release/vitra-spike /bin/cat .build/fixtures/load-100mb.txt
```

Reading of the input is verified, not assumed: the spike counts bytes as they
come off the pty and prints the total, so a fast run that silently dropped input
is distinguishable from a fast run that processed all of it.

800 KB of headroom across a 100 MB stream is the scrollback limiter and page
compression inside libghostty doing their job. There is no CPU figure for this
phase: the spike has no idle state to measure.

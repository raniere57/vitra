# Dependencies

Vitra ships as a single native binary. It has no runtime dependency on Node,
Electron, Python, or any external server process. The only third-party code
compiled into it is `libghostty-vt`.

## libghostty-vt

| | |
|---|---|
| Source | https://github.com/ghostty-org/ghostty |
| Pinned commit | `f64f4aca2c29b554d111b36c3d946a9bddd159ff` |
| Commit date | 2026-08-09 |
| Commit subject | `lib-vt: answer XTGETTCAP queries (#13530)` |
| Linkage | **static** (`ghostty-vt-static`) |
| License | MIT |

### Why the commit is pinned

`include/ghostty/vt.h` states the C API is a work in progress and that breaking
changes are expected. Tracking a branch would break the build at random. This
specific commit is the one `ghostty-org/ghostling` pins, which means it is a
combination of C API and reference integration that is known to work together.

### Build requirements (build time only, not runtime)

| Tool | Version | Install |
|---|---|---|
| Zig | 0.16.0 (`minimum_zig_version` in `build.zig.zon`) | `brew install zig` |
| Ninja | any recent | `brew install ninja` |

### Reproducing the vendored artifacts

```bash
scripts/vendor-ghostty-vt.sh          # no-op if already vendored at this commit
scripts/vendor-ghostty-vt.sh --force  # rebuild from scratch
```

The script fetches only the pinned commit (`--depth 1`), runs
`zig build -Demit-lib-vt -Doptimize=ReleaseFast`, installs into
`vendor/ghostty-vt/`, and copies the headers into
`Sources/CGhosttyVT/include/ghostty/`.

`-Demit-lib-vt` switches Ghostty's build into a libghostty-vt-only
configuration: no xcframework, no macOS app, no docs. `ReleaseFast` is not
optional — debug builds of Ghostty are very slow and memory-hungry, which
matters on an 8 GB machine.

Both `vendor/` and the copied headers are gitignored. The build is reproducible
from the pinned commit alone.

### Known upstream gaps

None blocking. The ghostling README lists OSC 52 clipboard as missing, but at
this pinned commit `GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE` is present and
`GHOSTTY_TERMINAL_OPT_*` covers bell, title, pwd, device attributes, colour
scheme, Kitty image storage, and desktop notifications. The README is stale.

## System frameworks

AppKit, SwiftUI, Metal, CoreText, PDFKit, WebKit, QuickLookThumbnailing,
CoreImage. All part of macOS 14+; nothing to install.

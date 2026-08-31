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

## Phase 1a - Metal renderer and terminal window

Commit: `fcd26f5`. Binary: `.build/release/VitraApp`, 2.0 MB. One window, 80x24,
Menlo 13pt on a Retina display.

| Scenario | phys_footprint | RSS | CPU |
|---|---|---|---|
| idle, window focused, shell at prompt | **14 MB** | 34.8 MB | **0.00%** |
| `cat` of the 100 MB fixture, steady state | **16 MB** | 62.4 MB | 0.00% after |
| peak across the whole load run | 16 MB | - | - |

Against a 150 MB budget, a loaded terminal costs 16 MB. The 2 MB delta between
idle and 100 MB of throughput is scrollback compression inside libghostty.

`phys_footprint` and RSS diverge by more than 2x. RSS counts shared framework
pages (AppKit, Metal, CoreText) that are mapped but not spent; `phys_footprint`
is what macOS charges the process and what Activity Monitor displays. Both are
reported, and `phys_footprint` is the one the budget is measured against.

CPU is 0.00% averaged over 10 one-second samples with the window focused and the
cursor blinking. That is the on-demand design working: no display link, and the
blink timer only runs while the window has focus and only redraws when the
terminal actually asked for a blinking cursor.

Reproduce:

```bash
scripts/measure.sh load
.build/release/VitraApp &
scripts/measure.sh live VitraApp
.build/release/VitraApp -e /bin/sh -c 'cat .build/fixtures/load-100mb.txt; exec sleep 600' &
scripts/measure.sh live VitraApp
```

### Launch cost

Measured separately because a terminal is judged on how fast it opens:

| Phase | Cost |
|---|---|
| `MTLCreateSystemDefaultDevice` | 43.2 ms |
| load `default.metallib` | 0.7 ms |
| glyph atlas (2048x2048 R8, 4 MB) | 4.1 ms |
| render pipeline, cold / warm | 1.8 ms / 0.3 ms |

The shader is compiled at build time by a SwiftPM plugin. Compiling it from
source at launch instead costs **463 ms**, which is why the plugin exists;
`swift build` does not compile `.metal` files on its own the way Xcode does.

## Phase 2 — attachments

Measured on the installed `Vitra.app` (Release, ad-hoc signed) unless a row says
otherwise. Each run is a fresh launch with `-e /bin/sh`.

| State | phys_footprint | peak | RSS | CPU |
|---|---|---|---|---|
| idle, bare `.build/release/VitraApp` | **25 MB** | 29 MB | 72.5 MB | 0.00% |
| idle, installed `.app` | **26 MB** | 30 MB | 75.4 MB | 0.00% |
| after pasting an image, chip and thumbnail on screen | **43 MB** | 54 MB | 86.9 MB | 0.00% |
| `cat` of the 100 MB fixture | **34 MB** | 38 MB | 64.1 MB | 0.00% |

Against the 150 MB budget the worst measured state is 43 MB.

Idle grew from Phase 1a's 14 MB to 25 MB. The measurement method is identical
(same script, same bare release binary), so the 11 MB is code: tabs, splits,
selection, pasteboard and drag-and-drop registration all arrived in between. It
is not attributed more finely than that because at 1/6 of the budget the split
would not change any decision.

The 17 MB step from pasting is QuickLook: `QLThumbnailGenerator` loads the
thumbnailing stack and the image decoders behind it. Kept on purpose — seeing
*which* screenshot was attached is the point of the chip, and a generic
`NSWorkspace` file icon would cost nothing and show nothing. Revisit if the
idle-after-paste number stops coming back down.

Reproduce:

```bash
scripts/measure.sh load
/Applications/Vitra.app/Contents/MacOS/Vitra -e /bin/sh &
scripts/measure.sh live $!
```

### Fork hazard found while measuring

The parallel test suite started failing at random once the suite grew to load
AppKit. The crash reports showed the cause: `crashed on child side of fork
pre-exec`, `os_unfair_lock is corrupt`, in `swift_conformsToProtocol`. The
child's setup between `fork()` and `execve()` was written in Swift, and the
Swift runtime takes locks that another thread can hold at fork time.

This was a production bug, not a test artifact: the app forks from a
multithreaded AppKit process every time a pane opens. `PTY` moved to
`posix_spawn` with `POSIX_SPAWN_SETSID` and a file action that opens the slave
by path, on the assumption that an open without `O_NOCTTY` acquires the
controlling terminal. 98 tests, 8 consecutive clean runs.

### The assumption was wrong, and measuring found it

Chasing a different bug — a session clicked in the sidebar being typed into
Claude Code's chat box instead of a shell — the pane was asked who held its
terminal:

```
[pty] tty=/dev/ttys007 fg=0 sid=-1 shell=50388 shellpgid=50388
```

`sid=-1`: the tty had **no session**. macOS does not hand out a controlling
terminal on open — that is the System V behaviour Linux implements. On BSD it
takes an explicit `ioctl(TIOCSCTTY)`, which is what `login_tty()` does and what
`posix_spawn` has no file action for. Every consequence followed from that one
missing line: the shell never turned on job control, `Ctrl-C` reached nobody,
`TIOCSWINSZ` delivered `SIGWINCH` to process group 0 — so a program kept
drawing at the old width after the preview panel closed — and `tcgetpgrp`
answered 0, which is why nothing could tell a busy pane from an idle one.

The fix keeps both properties: `Sources/CVitraSpawn` is thirty lines of C that
`fork`s, calls `setsid` + `TIOCSCTTY`, and `execve`s. No Swift runs in the
child, and failures before `exec` come back through a close-on-exec pipe so a
missing executable still throws instead of silently exiting 127.

```
[pty] tty=/dev/ttys007 fg=52297 sid=51848 shell=51848 shellpgid=51848
```

201 tests. Two of them now assert what was never asserted before: the child
owns the terminal's session, and a job it starts shows up in the foreground.

## Phase 3 — preview panel

Installed `Vitra.app`, fresh launch per row, file opened through `ESC ] 7337`.

| State | phys_footprint | peak | RSS | CPU |
|---|---|---|---|---|
| panel closed (idle) | **25 MB** | 30 MB | 44.7 MB | 0.00% |
| image preview open (92 KB PNG) | **25 MB** | 30 MB | 44.7 MB | 0.00% |
| web preview open, Vitra's own process | **31 MB** | 36 MB | 27.5 MB | 0.00% |
| the same preview's `WebKit.WebContent` process | **14 MB** | – | 28 MB | – |
| `cat` of the 100 MB fixture, panel closed | **34 MB** | 38 MB | 42.5 MB | 0.00% |

### The WebKit lifetime, verified

The 150 MB budget was the open risk in this phase, and the ambiguity in how to
count a `WKWebView` turns out not to matter: **45 MB for both processes together**
with a web page open, against a budget of 150 MB. Either reading passes.

WebKit is only mapped once a web preview is opened, and the content process is
gone as soon as the panel closes. Sampled during one run, with a page loaded and
then `Cmd-Shift-P` pressed:

```
t=3s (panel open)     4 WebContent processes: 48266  48729  48730  50369
t=8s (panel closed)   3 WebContent processes: 48266  48729  48730
```

The three survivors belong to other applications and predate the run; 50369 is
Vitra's, and it exits when `PreviewPanel.clearContent()` drops the view. Closing
the panel — not just switching files — is what releases it.

Reproduce:

```bash
printf '\033]7337;file=%s\a' "$PWD/page.html"   # inside Vitra
ps -axo pid,rss,comm | grep WebKit.WebContent   # before and after Cmd-Shift-P
```

## Phase 4 — browser and MCP

| State | phys_footprint | peak |
|---|---|---|
| idle, bridge listening, no browser | **33 MB** | 36 MB |
| browser open on a local page | **41 MB** | 45 MB |
| that page's `WebKit.WebContent` process | **16 MB** | – |

57 MB across both processes with a page loaded and automated, against a 150 MB
budget. The unix socket costs nothing measurable: it is one listening descriptor
and a dispatch source, and `vitra mcp` is a separate short-lived process that
exists only while the agent's client holds it open.

### Isolation, verified rather than asserted

The claim that automation cannot be seen by the page was checked by asking both
sides the same question:

```
browser_console  →  [log] page world sees __vitra as: undefined
browser_eval     →  object
```

The page's own script, running in the page world, cannot see the ref registry
that `browser_click` and `browser_type` depend on.

## Phase 5 — configuration and themes

| State | phys_footprint | peak | RSS |
|---|---|---|---|
| idle, config watcher and bridge running | **30 MB** | 34 MB | 70.4 MB |

The FSEvents watcher and the socket cost nothing measurable against Phase 4's
33 MB; the difference between the two numbers is noise between launches.

### Translucency, checked in the pixels

The window capture flattens alpha, so the check is a comparison rather than an
alpha read. Same theme, same point in the window, two runs:

| Configuration | pixel at the centre |
|---|---|
| `opacity = 1` | `rgb(13, 13, 18)` — the theme's background exactly |
| `opacity = 0.75, blur = true` | `rgb(18, 18, 23)` — composited over the blur layer |

### Hot reload

One run, one window: launched with `dark`, Menlo 13, padding 8. The file was
rewritten mid-session to `light`, SF Mono 15, padding 16. The window changed
theme, typeface, size and padding without a restart, and the ANSI colours in
already-printed output changed with it — a theme change dirties no cell, so the
render state is forced to re-read rather than waiting for the next keystroke.

## Folders

One window, four favourites loaded, measured with `footprint` four seconds after
launch:

| State | phys_footprint |
|---|---|
| One window, no panel | 30 MB |
| Peak during launch | 34 MB |

The bookmark list is a few hundred bytes of JSON read once at launch, and the
palette is built on first use and kept — a panel that is never opened costs
nothing. Opening a favourite as a tab costs what any tab costs: a pty, a
libghostty terminal and the scrollback it fills.

### Where the shell starts

`posix_spawn_file_actions_addchdir_np` puts the child in the folder before it
execs, so nothing in the app process changes directory. Verified in the suite
with `/bin/pwd` on a real pty, against the resolved path — `/var` is a symlink
to `/private/var`, and `pwd` reports the physical one.

## Command blocks

| State | phys_footprint |
|---|---|
| One window, gutter on, idle after launch | 35 MB |

The rails are an AppKit view drawn over the terminal, not geometry in the Metal
path: they are redrawn only when the block list changes, which happens when a
command starts or ends rather than on every keystroke. The one timer in the
feature runs only while a command is running — it ticks the `running · 7.2s`
clock ten times a second and is invalidated the moment the command ends, so an
idle terminal still schedules nothing. The semantic rows come
from libghostty's own OSC 133 bookkeeping (`GHOSTTY_ROW_DATA_SEMANTIC_PROMPT`),
so there is no second parser and nothing to keep in sync.

### The renderer was never the problem

Checked before designing anything: an SGR test run inside Vitra paints 8-colour,
bright, bold, 24-bit truecolour, reverse, underline and background attributes
correctly. What the screenshot showed was macOS `ls` shipping without colour and
no marks between commands - a missing feature, not a broken renderer.

## Sidebars

`footprint`, Release build, one window, launched fresh and left alone:

| State | phys_footprint |
|---|---|
| Rail collapsed, no panel | 31 MB |
| Folder tree expanded and the file list open | 44 MB |

Thirteen megabytes for an `NSOutlineView`, an `NSTableView` and the Finder icons
they show, against a 150 MB budget. Both lists are read on demand: the tree
reads a folder the first time it is opened and keeps it, the file list is read
when the panel opens and again when a command finishes — the moment the shell's
directory has settled. There is no file-system watcher and no timer behind
either, so an idle window with both sidebars open still schedules nothing.

A first measurement read 355 MB and was wrong: `pgrep` had matched the
long-running instance in `/Applications`, not the one just launched. Measuring
by the PID of the process actually started is the difference between a
regression and a mistake.

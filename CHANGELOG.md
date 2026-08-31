# Changelog

Every release, what changed in it, and the measurements behind the claims.
Dates are the day the disk image was built.

## 0.1.2 - 2026-08-31

- Fixed: a shell opened by Vitra no longer inherits the session markers of an
  agent that launched Vitra (`CLAUDECODE`, `CLAUDE_CODE_*`, `AI_AGENT`). A
  Claude Code started in such a pane believed it was a child of the session
  that opened the window and turned its own transcript off. Anything the user
  sets in a profile still comes back when the shell reads that profile.

## Unreleased

- Windows nobody is looking at stop drawing. A background tab, a minimised
  window or a hidden app now releases the GPU surfaces it was holding and stops
  its display link. Eight tabs went from **494 MB to 80 MB**, and 56 MB of
  output printed into a hidden window costs **0.03s of CPU instead of 0.21s**.
  Whatever is running keeps running, and comes back drawn.
- The glyph atlas is sized from the font's cell rather than always 2048x2048:
  1 MB instead of 4 MB at the default size.
- Fixed: the instance buffer was refilled while the GPU could still be reading
  the previous frame. Two buffers and a semaphore now.

## 0.1.1 - 2026-08-31

- Double-clicking the preview panel's divider maximises it over the whole
  window; `Esc` restores the split.
- Fixed: a pane no longer follows a layout down to a sliver. Maximising the
  panel used to resize the shell to a couple of columns, which made whatever
  was running reflow every line it held; Escape brought back a window of
  wreckage. A pane's size now reaches the program only while the pane is
  visible and wider than 100 points.
- Fixed: the split's divider is no longer drawn over the maximised panel.
- A tool call now starts Vitra when it is not running, instead of failing with
  "open Vitra and try again". The helper asks the system to open the bundle it
  is running out of, and runs the binary itself where the system will not.
- `browser_back` and `browser_forward`: history in the browser panel, each
  waiting for the page to actually change before answering.
- `browser_click` and `browser_type` with submit now wait out whatever
  navigation they started and report where the page landed, including
  single-page applications that change the address without loading anything.
  The answer says the old refs are gone, because they are.
- The default font is SF Mono instead of Menlo. It ships with macOS, so nothing
  is installed and nothing is bundled; `family = "SF Mono"` in the config now
  resolves through the system font, which is the only way to ask for it.

## 0.1.0 - 2026-08-31

First public build. A terminal that hosts CLI coding agents.

### The terminal

- libghostty-vt for the VT core, a Metal renderer with a Core Text glyph atlas,
  and no timer running when the screen is not changing.
- Splits, tabs and windows, with the focused pane ringed in the folder's colour.
- Scrollback, selection, copy and paste; the wheel goes to the program when it
  asks for the mouse, and to the scrollback when it does not.
- Command blocks: each command carries its own rail, its timing and its exit
  status, through shell integration for zsh.
- `Cmd-+`, `Cmd--` and `Cmd-0` change the font size everywhere at once.

### Around it

- **Sessions sidebar** - every Claude Code conversation on the machine, grouped
  by project, searchable, resumed into a new tab. The one you are in is marked.
- **Folder rail** - favourite directories with their own icon, colour and theme.
- **Attachments** - drop a file or paste an image and its path is typed into the
  prompt; the bytes never touch the pty.
- **Preview panel** - HTML, Markdown, images, PDFs and a browser, in a WKWebView
  created when it opens and destroyed when it closes.
- **Layout** - windows, tabs, splits, folders and sessions come back after a
  restart. The red button hides the app; `Cmd-Q` quits it.
- **MCP server** compiled into the binary: an agent inside Vitra can open a file
  in the preview or read the page it is looking at, and nothing else. No shell,
  no file you did not open.
- **CLI** - `vitra open <file>` shows a file in the preview panel.

### Measured

- About 80 MB of physical footprint for one window, 50 MB of which is the
  drawables the GPU composites from.
- 300,000 lines of scrollback cost about 2 MB.
- The full numbers, and how they were taken, are in
  [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md).

### Known limits

- The disk image is signed ad-hoc, not notarised, so a downloaded copy needs
  `xattr -dr com.apple.quarantine /Applications/Vitra.app`.
- Apple silicon and macOS 14 or later only.
- Shell integration covers zsh; bash and fish are not wired up yet.
- No ligatures and no colour emoji in the renderer yet.

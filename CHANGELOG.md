# Changelog

Every release, what changed in it, and the measurements behind the claims.
Dates are the day the disk image was built.

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

# Vitra

A native macOS terminal built to host Claude Code: attach files to the prompt,
preview what the agent produces, and stay out of the way of a MacBook Air with
8 GB of RAM.

One process, no runtime. Swift 6 and AppKit, [libghostty-vt](docs/DEPENDENCIES.md)
for the VT core, a Metal renderer with a Core Text glyph atlas, and WebKit that
is only loaded once a web preview is actually opened.

Requires macOS 14 or later on Apple silicon.

## Build

```bash
scripts/vendor-ghostty-vt.sh     # once: fetches and builds the pinned VT core
swift build
swift test
scripts/build-app.sh --install   # builds dist/Vitra.app and copies it to /Applications
```

## The CLI

`vitra` ships inside the app bundle. Link it onto your PATH:

```bash
ln -s /Applications/Vitra.app/Contents/Helpers/vitra /usr/local/bin/vitra
```

```bash
vitra open report.html    # show a file in the preview panel
```

## Attaching files

| Action | What happens |
|---|---|
| `Cmd-V` with an image on the clipboard | written to `~/.vitra/attachments/`, its path typed into the prompt |
| `Cmd-V` with files copied in the Finder | their paths typed into the prompt, files left where they are |
| Drag files onto the window | same as above |

Paths are quoted when they need it and inserted as a bracketed paste. Binary
data is never written to the pty. Attachments Vitra wrote are swept after seven
days, at launch.

## The preview panel

`Cmd-Shift-P` toggles the panel. Images, PDFs, HTML, SVG and text are rendered
by `CGImageSource`, PDFKit, WebKit and `NSTextView` respectively.

Three ways in, all equivalent:

```bash
vitra open shot.png
printf '\033]7337;file=%s\a' "$PWD/shot.png"   # from any program in the terminal
```

…and the MCP `preview_file` tool.

Relative paths are resolved against the working directory of the job in the
foreground. Only existing regular files open: symlinks are followed first, and
directories and devices are refused.

## The MCP server

Vitra serves eight tools to an agent running inside it:

```bash
claude mcp add vitra -- vitra mcp
```

| Tool | What it does |
|---|---|
| `preview_file` | show a file in the panel |
| `browser_open` | load a URL in the browser panel |
| `browser_snapshot` | list the visible, usable elements, each with a ref |
| `browser_click` | click a ref |
| `browser_type` | type into a ref, optionally submitting |
| `browser_eval` | run JavaScript and get the result |
| `browser_screenshot` | save a PNG and return its path |
| `browser_console` | read the page's console output |

`vitra mcp` is the same binary with no GUI. The agent's client spawns it, and it
forwards tool calls to the running window over `~/.vitra/vitra.sock`, which is
created with mode 0600. It lives and dies with the agent's session; nothing runs
in the background. With no window open, the tools answer "Vitra is not running"
instead of hanging.

### What the tools cannot do

- **No shell.** No tool runs a command. The terminal is yours.
- **No file access beyond what you name.** `preview_file` resolves symlinks and
  refuses anything that is not an existing regular file. Web pages are loaded
  with read access to the single file being shown, not to its directory.
- **No reach into the page's JavaScript.** `browser_snapshot`, `browser_click`,
  `browser_type` and `browser_eval` run in a WebKit isolated world: they see the
  DOM, the page does not see them. Verified, not assumed — a page asking for
  `typeof window.__vitra` gets `undefined` while the same expression in the
  isolated world answers `object`.

## Configuration

`~/.vitra/config.toml`, written on first launch. Saving it applies to every open
window immediately — font, theme, opacity, padding, scrollback and shell, with no
restart. `Cmd-,` opens a settings window that edits the same file.

```toml
[font]
family = "SF Mono"
size = 14

[window]
opacity = 0.92   # 0.5 to 1
blur = true
padding = 10

[terminal]
scrollback = 10000
# shell = "/bin/zsh"

[theme]
name = "dark"          # dark or light
cursor = "#e8e8ef"     # override any single colour
palette = [ ... ]      # or all sixteen

[keybindings]
split_right = "d"      # single characters, always with Command
```

A typo never stops a window from opening: the bad value is skipped, the default
stays, and the reason is printed.

## Keys

| Key | Action |
|---|---|
| `Cmd-T` / `Cmd-N` | new tab / window |
| `Cmd-D` / `Cmd-Shift-D` | split right / down |
| `Cmd-W` | close pane |
| `Cmd-Shift-P` | preview panel |
| `Cmd-K` | clear |
| `Cmd-C` / `Cmd-V` | copy / paste |

## Measurements

Every performance claim in this repository is measured, not estimated. The
numbers, the methods, and the scripts that produce them are in
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md).

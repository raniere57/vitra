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

…and the MCP `preview_file` tool, once the embedded server lands.

Relative paths are resolved against the working directory of the job in the
foreground. Only existing regular files open: symlinks are followed first, and
directories and devices are refused.

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

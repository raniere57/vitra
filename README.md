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

## Release

```bash
scripts/make-icon.sh             # draws the icon and packs dist/AppIcon.icns
scripts/release.sh               # size-optimised build, ad-hoc signature, dist/Vitra-<version>.dmg
```

The disk image is signed ad-hoc, not notarised: there is no Developer ID behind
this build, so Gatekeeper refuses a copy that arrived with the quarantine flag.
Clearing it is one command, and worth understanding rather than pasting:

```bash
xattr -dr com.apple.quarantine /Applications/Vitra.app
```

## The CLI

`vitra` ships inside the app bundle. Link it onto your PATH:

```bash
ln -s /Applications/Vitra.app/Contents/Helpers/vitra /usr/local/bin/vitra
```

```bash
vitra open report.html    # show a file in the preview panel
```

## Folders

Favourite directories live in `~/.vitra/bookmarks.json`, written by the app.
Each one carries an emoji, an optional colour, an optional theme and any number
of tags, and opening one starts a tab whose shell is already there.

Nothing here is hidden behind a shortcut. The favourites live on a **rail** down
the left edge - one click per folder, the window's own folder lit in its colour -
and `+` at the bottom opens the rest (go to, open, star, manage). The title bar
carries a **breadcrumb**: the folder, then where the focused shell has since
wandered. Two bare buttons sit before it — folders and sessions — each lit only
while its sidebar is open; splitting and the preview panel sit in one cluster at
the right.

The rail is the sidebar collapsed. `Opt-Cmd-S`, the title bar button, or simply
dragging the divider widens it into a **folder tree**: the favourites and home
as roots, subdirectories read only when a folder is opened. Clicking a folder
is a `cd` typed into the terminal you are already in - not a new tab, not a new
window - and `Cmd-click` is the exception that opens one. The folder the focused
shell is in is selected in the tree and the tree is opened down to it, so the
sidebar always says where you are, including after a `cd` you typed yourself.

Above the tree there is a **filter**: type part of a folder's name and the tree
becomes a flat list of matches, each with the folder it lives in. It searches one
level under every root plus everything already opened, which is what keeps it
instant — nothing walks the disk in the background. `Return` takes the first
result, `Esc` clears the field and hands the keyboard back to the terminal.

With more than one pane, the pane holding the keyboard carries a bar on its
leading edge, in the folder's colour. Panes and the preview panel are resized by
dragging the dividers: the line is a hairline, the grab band is five pixels
either side of it.

- `Cmd-P` is the quick switcher: type part of a name, a path or a tag and press
  Return. Terms are ANDed, so `api work` narrows rather than widens.
- `Cmd-Ctrl-D` stars whatever directory the focused shell is in right now, read
  from the process rather than from wherever the tab started.
- **Folders ▸ Manage Folders…** is where names, emoji, colours, themes and tags
  are edited.

A folder's theme wins over the one in the configuration, which is the point of
setting it: a tab on production should not look like a tab on a scratch
directory. Its colour becomes a two-pixel stripe under that window's title bar,
and its emoji prefixes the title, which is what the tab bar shows.

A window opens filled — the screen minus the menu bar and the Dock, the green
button's "Fill" rather than full screen, so the menu bar and every other window
stay where they are.

## Sessions

`Opt-Cmd-C`, or the second button in the title bar, opens the same sidebar on
the **Claude Code sessions of this machine** — the store the CLI and the desktop
app share, `~/.claude/projects/`. Clicking one types
`cd <project> && claude --resume <id>` into the pane that has the keyboard, so
the conversation reopens where it was, in the terminal you are already looking
at. The filter field searches titles and project names.

Sessions are grouped by project, newest project first, with a colour dot and the
count beside the name; clicking a project's name folds it away, which is what
keeps one busy repository from burying the other twenty. A hairline separates
one session from the next, and each row carries the title over the day and the
hour it was last worked on — today and yesterday named by the system, anything
older dated — because four sessions of the same project are told apart by *when*
and not by "4 days ago". A session run in a worktree gets the worktree as a chip
beside the date.

A compaction or a resume starts a *new* transcript, so one conversation can
leave a dozen files behind — which is why the list showed twenty-five sessions
of a project the app lists ten of. The app's index names the ids it has replaced
(`priorCliSessionIds`) and those are dropped; a transcript the index never heard
of is dropped too when it opens with the CLI's own "This session is being
continued…" summary, and two files with the same opening prompt in the same
project collapse to the newest — the one worth reopening. What survives is a
conversation, not a segment of one.

Sessions archived in the desktop app stay out of the list. The app keeps one
small JSON per session in `~/Library/Application Support/Claude/`, and that is
the only place `isArchived` — and the title the user gave the session — exists;
the transcript knows neither. When the app was never used here the index is
simply absent and every transcript is shown. The footer says how many are hidden
and puts them back with one click.

Titles come from that index first, then from the transcript's own `custom-title`,
falling back to the prompt the session started from, or to the slash command when
that is all it was. Only the newest transcripts are read, and only 32 KB from the
head and 64 KB from the tail of each: a session file runs to tens of megabytes
and the sidebar needs one line out of it. The read happens off the main thread,
the first time the list is shown — never at launch.

Clicking a session types `cd <project> && claude --resume <id>` into the pane
that has the keyboard — unless something is already running in it. A pane with a
program in the foreground reads what it is handed as *input*, which is how the
command used to end up in Claude Code's own chat box; the tty says who holds the
terminal (`tcgetpgrp`), and a busy pane gets the session in a new tab instead.

## Scrolling

The wheel and the trackpad scroll the scrollback, and a thin thumb appears on
the right edge while the viewport is off the live screen — never while it is at
the bottom, which is where a terminal spends its life. The position comes from
the terminal itself, once per frame it already draws: no scroll view, no timer,
nothing running while nothing scrolls. Typing puts the live screen back.

## Command blocks

The shell tells Vitra where each command starts and ends (OSC 133), and the
gutter draws it: a rail per command in its own column — green when the command
succeeded, red when it failed, amber while it runs — and, on the line you typed
the command on, its exit code and how long it took (`exit 127`, `running · 8.1s`;
a fast success is not labelled, because a column of `0.0s` is a column nobody
reads). The rail spans the command and its output, and starts at the command
itself, so the blank line between blocks stays blank.

A command that runs for more than half a minute — a shell inside `ssh`, an
editor — stops being amber and goes grey: it is still running, and it says so,
but it is no longer an alert, and its clock drops to one tick a second.

That needs shell integration, which Vitra installs by pointing `ZDOTDIR` at
`~/.vitra/shell/zsh` - shims that source your own `.zshenv`, `.zprofile`,
`.zshrc` and `.zlogin` first and then add the marks. Nothing of yours is edited.
zsh only for now. The same integration puts a blank line before each prompt so
the blocks are separated by space, sets `CLICOLOR` so `ls` and friends colour
their output, and colours the prompt **only if you have not styled it yourself**.
Each part is switchable:

```toml
[terminal]
shell_integration = true   # emit the marks
command_blocks = true      # draw the gutter
block_spacing = true       # a blank line before each prompt
color_prompt = true        # colour a stock, uncoloured prompt
color_defaults = true      # CLICOLOR for ls and friends
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

`Cmd-Shift-P` toggles the panel. It opens on the **files of the directory the
focused terminal is in**: one click previews a file, one click on a folder is
the same `cd` the left sidebar does, and `../` walks up. Images, PDFs, HTML, SVG
and text are rendered by `CGImageSource`, PDFKit, WebKit and `NSTextView`
respectively; the arrow in the header goes back to the list.

The list is re-read when a command finishes, which is the moment the directory
has settled - there is no watcher and no timer behind it.

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
| `Opt-Cmd-S` | folder sidebar |
| `Opt-Cmd-C` | sessions sidebar |
| `Cmd-P` | go to folder |
| `Cmd-Shift-O` | new tab in a folder |
| `Cmd-Ctrl-D` | add the current folder |
| `Cmd-Ctrl-1`…`9` | open the first nine folders |
| `Cmd-K` | clear |
| `Cmd-C` / `Cmd-V` | copy / paste |

## Measurements

Every performance claim in this repository is measured, not estimated. The
numbers, the methods, and the scripts that produce them are in
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md).

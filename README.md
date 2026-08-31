<div align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Vitra" />
  <h1>Vitra</h1>
  <p><strong>A native macOS terminal built to host CLI coding agents.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/arch-Apple%20silicon-111" alt="Apple silicon" />
    <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6" />
    <a href="https://github.com/raniere57/vitra/releases/latest"><img src="https://img.shields.io/github/v/release/raniere57/vitra?color=2f81f7" alt="latest release" /></a>
    <img src="https://img.shields.io/badge/license-MIT-111" alt="MIT" />
  </p>
</div>

![Vitra with two panes, the folder rail and command blocks](docs/hero.png)

## What it is

You already run Claude Code, Codex or another agent in a terminal. Vitra is the
window around that: your Claude Code sessions listed in a sidebar and resumed
with one click, files attached to the prompt by dragging them onto the pane,
whatever the agent writes rendered in a preview panel beside it, and the whole
workspace - windows, tabs, splits, folders - back where you left it after a
restart.

It is a real terminal underneath, not a wrapper: [libghostty-vt](docs/DEPENDENCIES.md)
drives the VT core and a Metal renderer with a Core Text glyph atlas draws it.
`vim`, `ssh` and `top` behave the way they do in any other terminal.

- **Sessions** - every Claude Code conversation on the machine, grouped by
  project, searchable, resumed into a new tab. The one you are in is marked.
- **Folders** - favourite directories on a rail down the left edge, each with
  its own icon, colour and theme; one click opens a tab already there.
- **Attachments** - drop a file or paste an image and its path is typed into
  the prompt. Bytes never go near the pty.
- **Preview panel** - HTML, Markdown, images, PDFs and a real browser, in a
  WKWebView that is created when you open it and destroyed when you close it.
- **Command blocks** - each command is a block with its own rail, timing and
  exit status.
- **MCP server** - compiled into the binary, so an agent running inside Vitra
  can open a file in the preview or read the page it is looking at. It cannot
  run a shell command or read a file you did not open.
- **Light** - one process. About 80 MB of memory for a window, and no timer
  running when the screen is not changing. Every number in
  [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md) is measured, not estimated.

Requires macOS 14 or later on Apple silicon.

## Install

Download the disk image from
[the latest release](https://github.com/raniere57/vitra/releases/latest), drag
Vitra to Applications, and clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Vitra.app
```

That last step is needed because the image is signed ad-hoc and not notarised -
there is no Developer ID behind this build. It is worth understanding rather
than pasting: the flag is what macOS puts on anything downloaded, and clearing
it says you trust this copy.

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

Arranging the icons inside the image is done by scripting Finder, so the first
run asks for Automation permission; without it the image still works, it just
opens as a list. Every release is written up in [CHANGELOG.md](CHANGELOG.md).

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
and `+` at the bottom opens the rest (go to, open, star, manage). Favourites are
drawn as SF Symbols rather than emoji — one weight, one size, one column — and
the picker in the folders window is that same set; a favourite made before icons
existed keeps the glyph its emoji stood for. The title bar
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

With more than one pane, the pane holding the keyboard is ringed in the folder's
colour. Panes and the preview panel are resized by
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

## How the sidebars are drawn

Both halves are one surface, so they are drawn to one set of measurements: the
same margin for the search field, the rows and the footer, the same rounded
plate under a row, the same hairline between groups. A row lights under the
pointer, and the plate is inset from both edges rather than bleeding across the
column, which is what the stock selection does.

The system's own table styling is off in both: its inset style pads every
group row with a band of its own, and that band is where the uneven gaps
between projects came from.

## Sessions

`Opt-Cmd-C`, or the second button in the title bar, opens the same sidebar on
the **Claude Code sessions of this machine** — the store the CLI and the desktop
app share, `~/.claude/projects/`. Clicking one types
`cd <project> && claude --resume <id>` into the pane that has the keyboard, so
the conversation reopens where it was, in the terminal you are already looking
at. The filter field searches titles and project names.

Sessions are grouped by project, newest project first, with a colour dot and the
count beside the name; projects start folded and a click opens one, which keeps
one busy repository from burying the other sixteen — every project fits on the
screen at once. A hairline separates
one session from the next, and each row carries the title over the day and the
hour it was last worked on — today and yesterday named by the system, anything
older dated — because four sessions of the same project are told apart by *when*
and not by "4 days ago". A session run in a worktree gets the worktree as a chip
beside the date.

The session the focused pane is in carries an accent rail down its leading edge,
a heavier title, and its project opens to show it — a mark behind a fold answers
the question for nobody. The session is known outright when the sidebar started
it, and recognised otherwise: Claude Code names the terminal after the
conversation, so a pane running a program in a folder that has sessions is
matched to the one whose title it is wearing. Titles drift — the transcript's
summary is rewritten as a conversation goes on, and a long one reaches the
terminal cut short — so a title that is a prefix of the other counts, and a pane
plainly running Claude Code in a project falls back to that project's newest
session. Between them, the sessions started by hand, resumed from inside Claude
Code, or begun by a compaction are all marked. It reads: with a dozen conversations sharing three or four names,
"which one am I in" is otherwise a question the sidebar cannot answer. It is a
mark and not a selection — selection is the row you clicked last, which is a
different question — and it follows the keyboard from pane to pane, clearing
itself when the session ends.

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

A folder in that list browses the list itself, and takes the terminal along
with a `cd` when the shell is free to take one. When something is running in
the pane — Claude Code, vim, less — nothing is typed at it: the tty says who
holds the terminal, and the list moves on its own. The same rule decides what a
folder in the left sidebar does: `cd` in a free pane, a new tab in a busy one.

## Links

A URL in the output is a link: one click opens it in the preview panel — a page
you glance at without leaving the window — and `Cmd`-click hands it to your
browser. The pointer turns into a hand over one. Scheme-less `www.` hosts count,
a full stop at the end of a sentence does not, and a bracket the link never
opened is left behind.

## Keys the Mac already has

`Cmd-Backspace`, `Cmd-Delete`, `Cmd-←` and `Cmd-→` do in a shell what they do
everywhere else on the Mac: clear the line back, clear it forward, jump to the
start, jump to the end. Command is not a terminal modifier — no escape sequence
carries it — so these are translated into the control characters every line
editor already answers to.

## Scrolling

The wheel and the trackpad scroll the scrollback, and a thin thumb appears on
the right edge while the viewport is off the live screen — never while it is at
the bottom, which is where a terminal spends its life. The position comes from
the terminal itself, once per frame it already draws: no scroll view, no timer,
nothing running while nothing scrolls. Typing puts the live screen back.

A full-screen program — Claude Code, `vim`, `less` — is on the alternate
screen, which has no scrollback at all, so scrolling the viewport there would
move nothing. The wheel goes to the program instead: as a mouse report when it
asked to hear about the mouse (SGR, or the legacy encoding when that is all it
knows), and as arrow keys when it did not, which is what makes a pager follow
the wheel. Vitra reads which of those applies from the terminal itself rather
than guessing.

`Shift+Page Up` and `Shift+Page Down` move by a screen without a hand on the
trackpad, and `Shift+Home` and `Shift+End` go to the top of the scrollback and
back to the live screen. Shift is what says the key is for the terminal and not
for the program running in it, so an application that uses the page keys keeps
getting them unshifted.

## The cursor

A bar, not a block, and that is a decision rather than a default: a block covers
the character after the insertion point, so it shows you a letter when what you
wanted was the gap the next letter goes into. `terminal.cursor_style` takes
`bar`, `block`, `underline`, `hollow` or `auto`; `auto` hands the choice back to
whatever program is running. A pane that is not the key window always shows a
hollow block — the position is still worth knowing, the claim on your typing is
not.

## The red button hides

A window here is not a document: it holds running shells and a Claude Code
session that took ten minutes to get into, so the red button puts Vitra away
rather than closing it. Everything keeps running, and clicking the Dock icon
brings it back exactly as it was — no restore, because nothing was lost.

Closing a tab still closes it: that button means "close this tab", and the rest
of the workspace stays on screen. It is the last window — the one that is the
whole app — that hides instead.

Quitting is `Cmd-Q`, or Quit from the Dock icon's menu, and that is when the
layout is written down. `Close Window` in the File menu closes one window for
real, ending what runs in it; `Close Pane` and the × in a pane's corner close
one terminal.

## Closing a pane

A × in the pane's top-right corner, shown while the pointer is in that pane and
gone when it leaves: closing a terminal by typing `exit` means going into it
first, which is two moves for something the pointer is already over. It is
hidden at rest because a button parked over the corner of every pane is a button
covering the text scrolling past it. `Cmd-W` still does the same thing from the
keyboard, and the last pane takes the window with it.

## The workspace comes back

Quitting writes the arrangement to `~/.vitra/layout.json`, and the next launch
opens it again: the windows and their tabs, the split tree at the proportions
you left it, the folder each pane was in, the sidebar you had open and on which
of its two halves. A pane that was in a Claude Code session runs
`claude --resume <id>` for you — recognised the same way the sidebar marks it,
so a session started by hand comes back too, because that is the part that is minutes of work
to rebuild by hand.

The scrollback does not come back. A restored pane is a fresh shell in the same
folder — replaying output no program produced would be a lie, and a terminal
that lies about what ran in it is worse than one that starts empty.

Nothing is remembered for a window opened on a command (`vitra -e …`): that is a
one-off, not a workspace. Deleting the file is how you start clean.

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


Double-clicking the divider gives the panel the whole window, and `Esc` gives
the terminal its half back. The panes are hidden rather than squeezed to
nothing: a pane resized to a sliver would reflow every line it holds, twice,
for a view nobody is reading.
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
| `browser_click` | click a ref, waiting out whatever it navigates to |
| `browser_type` | type into a ref, optionally submitting |
| `browser_back` / `browser_forward` | step through the panel's history |
| `browser_eval` | run JavaScript and get the result |
| `browser_screenshot` | save a PNG and return its path |
| `browser_console` | read the page's console output |

A tool call made while Vitra is closed opens it: the helper that serves the
tools lives inside the bundle, so it asks the system to open that exact copy,
and runs the binary itself in a session where the system will not.

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
restart. The default face is **SF Mono**, which ships with macOS - it carries no
public family name, so Vitra resolves that one name through the system rather
than through the font list; any other installed family is named as itself
(`JetBrains Mono`, `Menlo`, `Fira Code`), and a name that resolves to nothing
falls back to Menlo. `Cmd-,` opens a settings window that edits the same file, and `Cmd-+`
and `Cmd--` write the font size into it — zooming is a setting like any other,
so it survives a restart and reaches every window at once.

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
cursor_style = "bar"   # bar, block, underline, hollow, or auto
# shell = "/bin/zsh"

[theme]
name = "dark"          # dark or light
cursor = "#7cc0ff"     # override any single colour
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
| `Cmd-+` / `Cmd--` / `Cmd-0` | font bigger, smaller, back to 13pt |
| `Cmd-K` | clear |
| `Cmd-C` / `Cmd-V` | copy / paste |

## Measurements

Every performance claim in this repository is measured, not estimated. The
numbers, the methods, and the scripts that produce them are in
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md).

import CGhosttyVT
import VitraCore

extension GhosttyTerminalCore {
    /// Hands the theme to libghostty, which is what makes the render snapshot
    /// come back in these colours: the renderer reads defaults and palette
    /// entries out of the terminal, never from a second copy kept up here.
    public func apply(theme: Theme) {
        var background = rgb(theme.background)
        var foreground = rgb(theme.foreground)
        var cursor = rgb(theme.cursor)
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)

        var palette = theme.fullPalette.map(rgb)
        palette.withUnsafeMutableBufferPointer { buffer in
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress)
        }

        // No cell changed, so nothing is dirty; the next read has to happen
        // anyway or the screen keeps the old colours until something is typed.
        renderReader.forceNextUpdate = true
    }

    /// Caps retained history. libghostty prunes a page at a time, so the real
    /// number lands a little above what is asked for; its own documentation says
    /// so, and this is the knob it offers.
    public func setScrollback(lines: Int) {
        var limit = size_t(max(0, lines))
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &limit)
    }

    private func rgb(_ color: TerminalColor) -> GhosttyColorRgb {
        GhosttyColorRgb(r: color.red, g: color.green, b: color.blue)
    }
}

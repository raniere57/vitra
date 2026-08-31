import CGhosttyVT
import Foundation
import VitraCore

/// Reads grid state out of libghostty's render state into a `RenderSnapshot`.
///
/// The render state and its iterators are created once and reused for the life
/// of the session. libghostty populates pre-allocated iterator handles on each
/// update, so a steady-state redraw allocates nothing on either side of the
/// boundary.
final class RenderStateReader {
    private let state: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells

    /// Scratch space for one cell's UTF-8 grapheme cluster. 32 bytes covers
    /// every realistic cluster, including ZWJ emoji sequences.
    private var graphemeScratch = [UInt8](repeating: 0, count: 32)

    init() throws {
        var state: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state else {
            throw TerminalCoreError.allocationFailed
        }
        self.state = state

        var iterator: GhosttyRenderStateRowIterator?
        guard ghostty_render_state_row_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS,
              let iterator
        else {
            ghostty_render_state_free(state)
            throw TerminalCoreError.allocationFailed
        }
        self.rowIterator = iterator

        var cells: GhosttyRenderStateRowCells?
        guard ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS, let cells else {
            ghostty_render_state_row_iterator_free(iterator)
            ghostty_render_state_free(state)
            throw TerminalCoreError.allocationFailed
        }
        self.rowCells = cells
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(state)
    }

    /// Refills `snapshot` from `terminal`, or returns false if nothing changed.
    /// Set when something outside the grid changed and the next read must
    /// happen even though no cell is dirty.
    var forceNextUpdate = false

    func update(from terminal: GhosttyTerminal, into snapshot: RenderSnapshot) throws -> Bool {
        let result = ghostty_render_state_update(state, terminal)
        guard result == GHOSTTY_SUCCESS else {
            throw TerminalCoreError.operationFailed("render_state_update", code: result.rawValue)
        }

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        // ponytail: any dirty row redraws the whole grid. A full 80x24 refill is
        // ~30 KB of instance data; switch to per-row dirty tracking only if that
        // shows up in a profile.
        // A theme change alters no cell, so libghostty reports nothing dirty
        // while every colour on screen is now wrong. This is how that gets drawn.
        if forceNextUpdate {
            forceNextUpdate = false
        } else {
            guard dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE else { return false }
        }

        var columns: UInt16 = 0
        var rows: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        guard ghostty_render_state_colors_get(state, &colors) == GHOSTTY_SUCCESS else {
            throw TerminalCoreError.operationFailed("render_state_colors_get", code: 0)
        }

        snapshot.beginFrame(
            columns: columns,
            rows: rows,
            foreground: TerminalColor(colors.foreground),
            background: TerminalColor(colors.background)
        )
        snapshot.cursor = readCursor(colors: colors)

        fillCells(into: snapshot, colors: colors)

        // The render state stays dirty until the consumer says it has drawn. Not
        // clearing it here would make every frame report changes and defeat the
        // whole on-demand rendering design.
        var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)

        return true
    }

    // MARK: - Cursor

    private func readCursor(colors: GhosttyRenderStateColors) -> CursorSnapshot? {
        var visible = false
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        guard visible else { return nil }

        // The cursor can be scrolled out of the viewport, in which case its
        // coordinates are undefined rather than merely off-screen.
        var inViewport = false
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport)
        guard inViewport else { return nil }

        var x: UInt16 = 0
        var y: UInt16 = 0
        var blinking = false
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)

        return CursorSnapshot(
            column: x,
            row: y,
            style: CursorStyle(style),
            isBlinking: blinking,
            color: colors.cursor_has_value ? TerminalColor(colors.cursor) : TerminalColor(colors.foreground)
        )
    }

    // MARK: - Cells

    private func fillCells(into snapshot: RenderSnapshot, colors: GhosttyRenderStateColors) {
        var iterator: GhosttyRenderStateRowIterator? = rowIterator
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS
        else { return }

        let defaultForeground = TerminalColor(colors.foreground)
        let defaultBackground = TerminalColor(colors.background)

        var row = 0
        while ghostty_render_state_row_iterator_next(rowIterator), row < Int(snapshot.rows) {
            defer { row += 1 }

            // One selection query per row instead of one per cell, as the API
            // documentation recommends for span-based renderers.
            var selection = GhosttyRenderStateRowSelection()
            selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let hasSelection = ghostty_render_state_row_get(
                rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection
            ) == GHOSTTY_SUCCESS

            var cells: GhosttyRenderStateRowCells? = rowCells
            guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS
            else { continue }

            var column = 0
            while ghostty_render_state_row_cells_next(rowCells), column < Int(snapshot.columns) {
                defer { column += 1 }

                var cell = RenderCell(foreground: defaultForeground, background: defaultBackground)
                readText(into: &cell, snapshot: snapshot)
                readStyle(into: &cell)
                readColors(into: &cell)

                if hasSelection, column >= Int(selection.start_x), column <= Int(selection.end_x) {
                    cell.flags.insert(.selected)
                }
                snapshot.setCell(cell, column: column, row: row)
            }
        }
    }

    private func readText(into cell: inout RenderCell, snapshot: RenderSnapshot) {
        var buffer = GhosttyBuffer()
        let written: Int = graphemeScratch.withUnsafeMutableBufferPointer { scratch in
            buffer.ptr = scratch.baseAddress
            buffer.cap = scratch.count
            let result = ghostty_render_state_row_cells_get(
                rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer
            )
            return result == GHOSTTY_SUCCESS ? buffer.len : 0
        }
        guard written > 0 else { return }

        let location = graphemeScratch.withUnsafeBytes { bytes in
            snapshot.appendText(UnsafeRawBufferPointer(rebasing: bytes[0 ..< written]))
        }
        cell.textOffset = location.offset
        cell.textLength = location.length
    }

    private func readStyle(into cell: inout RenderCell) {
        // Most cells are unstyled; skipping the full style fetch for those is the
        // difference between one C call per cell and four.
        var hasStyling = false
        guard ghostty_render_state_row_cells_get(
            rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling
        ) == GHOSTTY_SUCCESS, hasStyling else { return }

        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        guard ghostty_render_state_row_cells_get(
            rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style
        ) == GHOSTTY_SUCCESS else { return }

        var flags: CellFlags = []
        if style.bold { flags.insert(.bold) }
        if style.italic { flags.insert(.italic) }
        if style.faint { flags.insert(.faint) }
        if style.blink { flags.insert(.blink) }
        if style.inverse { flags.insert(.inverse) }
        if style.invisible { flags.insert(.invisible) }
        if style.strikethrough { flags.insert(.strikethrough) }
        if style.overline { flags.insert(.overline) }
        if style.underline != 0 { flags.insert(.underline) }
        cell.flags.formUnion(flags)
    }

    private func readColors(into cell: inout RenderCell) {
        // These report GHOSTTY_INVALID_VALUE when the cell has no explicit colour,
        // which is not an error: it means "use the terminal default", already set.
        var foreground = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(
            rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground
        ) == GHOSTTY_SUCCESS {
            cell.foreground = TerminalColor(foreground)
        }

        var background = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(
            rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background
        ) == GHOSTTY_SUCCESS {
            cell.background = TerminalColor(background)
        }
    }
}

extension TerminalColor {
    init(_ rgb: GhosttyColorRgb) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

extension CursorStyle {
    init(_ style: GhosttyRenderStateCursorVisualStyle) {
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: self = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: self = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: self = .blockHollow
        default: self = .block
        }
    }
}

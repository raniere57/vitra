import CGhosttyVT
import Foundation
import VitraCore

extension GhosttyTerminalCore {
    public var isBracketedPasteEnabled: Bool {
        var config = GhosttyTerminalModeConfig()
        config.mode = ghostty_mode_new(2004, false)
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS
        else { return false }
        return config.value
    }

    public func screenPosition(viewportColumn: UInt16, viewportRow: UInt16) -> GridPosition? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: viewportColumn, y: UInt32(viewportRow))

        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS else { return nil }

        var screen = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(
            handle, &ref, GHOSTTY_POINT_TAG_SCREEN, &screen
        ) == GHOSTTY_SUCCESS else { return nil }

        return GridPosition(column: screen.x, row: screen.y)
    }

    public func setSelection(
        from start: GridPosition,
        to end: GridPosition,
        mode: SelectionMode,
        rectangle: Bool
    ) {
        guard var startRef = gridRef(at: start), var endRef = gridRef(at: end) else { return }

        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.rectangle = rectangle

        switch mode {
        case .cell:
            selection.start = startRef
            selection.end = endRef

        case .word:
            // Each end is widened to its own word, then the union is taken, so
            // dragging from the middle of one word to the middle of another
            // selects both whole words.
            guard let first = word(at: &startRef), let last = word(at: &endRef) else { return }
            selection.start = first.start
            selection.end = last.end

        case .line:
            guard let first = line(at: &startRef), let last = line(at: &endRef) else { return }
            selection.start = first.start
            selection.end = last.end
        }

        install(selection)
    }

    public func selectAll() {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_all(handle, &selection) == GHOSTTY_SUCCESS else { return }
        install(selection)
    }

    public func clearSelection() {
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    public func selectedText() -> String? {
        // Plain, unwrapped, trimmed: the combination the API documents as
        // matching what Ghostty itself puts on the clipboard, so a soft-wrapped
        // command comes back as one line instead of two.
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        options.selection = nil

        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(handle, nil, options, &pointer, &length) == GHOSTTY_SUCCESS,
              let pointer, length > 0
        else { return nil }
        defer { ghostty_free(nil, pointer, length) }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    /// Encodes text for the pty, honouring bracketed paste.
    ///
    /// libghostty strips control bytes and wraps the payload, which is what stops
    /// a pasted newline from executing on its own.
    public func encodePaste(_ text: String) -> [UInt8] {
        var input = Array(text.utf8).map { CChar(bitPattern: $0) }
        let bracketed = isBracketedPasteEnabled

        var required = 0
        _ = input.withUnsafeMutableBufferPointer { data in
            ghostty_paste_encode(data.baseAddress, data.count, bracketed, nil, 0, &required)
        }
        guard required > 0 else { return [] }

        var output = [CChar](repeating: 0, count: required)
        var written = 0
        let result = input.withUnsafeMutableBufferPointer { data in
            output.withUnsafeMutableBufferPointer { buffer in
                ghostty_paste_encode(
                    data.baseAddress, data.count, bracketed,
                    buffer.baseAddress, buffer.count, &written
                )
            }
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return output[0 ..< written].map { UInt8(bitPattern: $0) }
    }

    // MARK: - Helpers

    private func gridRef(at position: GridPosition) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(x: position.column, y: position.row)

        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    private func word(at ref: inout GhosttyGridRef) -> GhosttySelection? {
        var options = GhosttyTerminalSelectWordOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        options.ref = ref

        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_word(handle, &options, &selection) == GHOSTTY_SUCCESS
        else { return nil }
        return selection
    }

    private func line(at ref: inout GhosttyGridRef) -> GhosttySelection? {
        var options = GhosttyTerminalSelectLineOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
        options.ref = ref

        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_line(handle, &options, &selection) == GHOSTTY_SUCCESS
        else { return nil }
        return selection
    }

    private func install(_ selection: GhosttySelection) {
        var copy = selection
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &copy)
    }
}

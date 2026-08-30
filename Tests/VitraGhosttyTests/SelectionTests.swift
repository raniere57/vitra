import Testing
import VitraCore
@testable import VitraGhostty

private func terminal(
    _ input: String,
    size: TerminalSize = TerminalSize(columns: 20, rows: 4)
) throws -> GhosttyTerminalCore {
    let core = try GhosttyTerminalCore(size: size)
    core.feed(input)
    return core
}

@Test func viewportPositionsResolveToScreenPositions() throws {
    let core = try terminal("one\r\ntwo\r\nthree")
    let position = try #require(core.screenPosition(viewportColumn: 1, viewportRow: 1))
    #expect(position.column == 1)
    #expect(position.row == 1)
}

@Test func selectingCellsReturnsTheirText() throws {
    let core = try terminal("hello world")
    core.setSelection(
        from: GridPosition(column: 0, row: 0),
        to: GridPosition(column: 4, row: 0),
        mode: .cell,
        rectangle: false
    )
    #expect(core.selectedText() == "hello")
}

@Test func selectingAcrossRowsJoinsThem() throws {
    let core = try terminal("ab\r\ncd")
    core.setSelection(
        from: GridPosition(column: 0, row: 0),
        to: GridPosition(column: 1, row: 1),
        mode: .cell,
        rectangle: false
    )
    #expect(core.selectedText() == "ab\ncd")
}

@Test func wordModeWidensToWholeWords() throws {
    // Clicking the "e" of "hello" must select "hello", not "e".
    let core = try terminal("hello world")
    core.setSelection(
        from: GridPosition(column: 1, row: 0),
        to: GridPosition(column: 1, row: 0),
        mode: .word,
        rectangle: false
    )
    #expect(core.selectedText() == "hello")
}

@Test func wordModeDragSpansBothWords() throws {
    let core = try terminal("hello world")
    core.setSelection(
        from: GridPosition(column: 1, row: 0),
        to: GridPosition(column: 8, row: 0),
        mode: .word,
        rectangle: false
    )
    #expect(core.selectedText() == "hello world")
}

@Test func lineModeSelectsTheWholeLine() throws {
    let core = try terminal("first line\r\nsecond")
    core.setSelection(
        from: GridPosition(column: 3, row: 0),
        to: GridPosition(column: 3, row: 0),
        mode: .line,
        rectangle: false
    )
    #expect(core.selectedText() == "first line")
}

@Test func selectAllCoversEveryRow() throws {
    let core = try terminal("one\r\ntwo")
    core.selectAll()
    let text = try #require(core.selectedText())
    #expect(text.contains("one"))
    #expect(text.contains("two"))
}

@Test func clearingSelectionRemovesIt() throws {
    let core = try terminal("hello")
    core.selectAll()
    #expect(core.selectedText() != nil)
    core.clearSelection()
    #expect(core.selectedText() == nil)
}

@Test func selectionIsVisibleInTheRenderSnapshot() throws {
    // The renderer paints selection from per-cell flags, so the selection has to
    // reach the snapshot, not just the clipboard.
    let core = try terminal("hello world")
    core.setSelection(
        from: GridPosition(column: 0, row: 0),
        to: GridPosition(column: 4, row: 0),
        mode: .cell,
        rectangle: false
    )
    let snapshot = RenderSnapshot()
    #expect(try core.updateSnapshot(snapshot))

    #expect(snapshot[0, 0].flags.contains(.selected))
    #expect(snapshot[4, 0].flags.contains(.selected))
    #expect(!snapshot[5, 0].flags.contains(.selected))
}

@Test func selectionSurvivesScrolling() throws {
    // Screen coordinates, not viewport coordinates: output arriving mid-drag
    // must not drag the selection along with it.
    let core = try terminal("target\r\n", size: TerminalSize(columns: 20, rows: 2))
    let anchor = try #require(core.screenPosition(viewportColumn: 0, viewportRow: 0))

    core.feed("filler\r\nmore\r\n")

    core.setSelection(
        from: anchor,
        to: GridPosition(column: 5, row: anchor.row),
        mode: .cell,
        rectangle: false
    )
    #expect(core.selectedText() == "target")
}

// MARK: - Paste

@Test func pasteIsBracketedOnlyWhenTheProgramAsks() throws {
    let core = try terminal("")
    #expect(core.isBracketedPasteEnabled == false)
    #expect(String(decoding: core.encodePaste("hi"), as: UTF8.self) == "hi")

    core.feed("\u{1B}[?2004h")
    #expect(core.isBracketedPasteEnabled)
    #expect(String(decoding: core.encodePaste("hi"), as: UTF8.self) == "\u{1B}[200~hi\u{1B}[201~")
}

@Test func unbracketedPasteConvertsNewlinesToCarriageReturns() throws {
    // A bare \n would be swallowed by line discipline; \r is what the Return key
    // sends and what the shell expects.
    let core = try terminal("")
    #expect(String(decoding: core.encodePaste("a\nb"), as: UTF8.self) == "a\rb")
}

@Test func pasteStripsEscapeSequences() throws {
    // Pasted text must never be able to inject control sequences into the
    // terminal, whatever the clipboard happens to contain.
    let core = try terminal("")
    let encoded = String(decoding: core.encodePaste("safe\u{1B}[31mred"), as: UTF8.self)
    #expect(!encoded.contains("\u{1B}"))
    #expect(encoded.contains("safe"))
}

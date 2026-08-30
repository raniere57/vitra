import Testing
import VitraCore
@testable import VitraGhostty

private func snapshot(
    of input: String,
    size: TerminalSize = TerminalSize(columns: 10, rows: 3)
) throws -> RenderSnapshot {
    let core = try GhosttyTerminalCore(size: size)
    core.feed(input)
    let snapshot = RenderSnapshot()
    #expect(try core.updateSnapshot(snapshot))
    return snapshot
}

/// The text of one row, with trailing blanks trimmed.
private func rowText(_ snapshot: RenderSnapshot, _ row: Int) -> String {
    (0 ..< Int(snapshot.columns))
        .map { snapshot.text(of: snapshot[$0, row]) ?? " " }
        .joined()
        .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
}

@Test func snapshotMatchesGridDimensions() throws {
    let snapshot = try snapshot(of: "hi", size: TerminalSize(columns: 10, rows: 3))
    #expect(snapshot.columns == 10)
    #expect(snapshot.rows == 3)
    #expect(snapshot.cells.count == 30)
}

@Test func snapshotPlacesCharactersInCells() throws {
    let snapshot = try snapshot(of: "ab\r\ncd")
    #expect(rowText(snapshot, 0) == "ab")
    #expect(rowText(snapshot, 1) == "cd")
    #expect(rowText(snapshot, 2) == "")
}

@Test func unchangedTerminalReportsNothingToRedraw() throws {
    // This is the whole basis of the CPU budget: a static screen must not
    // produce frames.
    let core = try GhosttyTerminalCore(size: TerminalSize(columns: 10, rows: 3))
    let snapshot = RenderSnapshot()
    core.feed("hello")
    #expect(try core.updateSnapshot(snapshot))
    #expect(try core.updateSnapshot(snapshot) == false)

    core.feed("!")
    #expect(try core.updateSnapshot(snapshot))
}

@Test func explicitForegroundColourIsResolved() throws {
    // SGR 38;2 is truecolor: the exact RGB must survive to the renderer.
    let snapshot = try snapshot(of: "\u{1B}[38;2;10;20;30mX")
    #expect(snapshot[0, 0].foreground == TerminalColor(red: 10, green: 20, blue: 30))
}

@Test func paletteColourIsResolvedThroughThePalette() throws {
    // SGR 31 is palette index 1; the renderer must receive RGB, not an index.
    let snapshot = try snapshot(of: "\u{1B}[31mX")
    let red = snapshot[0, 0].foreground
    #expect(red != snapshot.defaultForeground)
    #expect(red.red > red.green && red.red > red.blue)
}

@Test func unstyledCellsFallBackToTerminalDefaults() throws {
    let snapshot = try snapshot(of: "X")
    #expect(snapshot[0, 0].foreground == snapshot.defaultForeground)
    #expect(snapshot[0, 0].background == snapshot.defaultBackground)
}

@Test func textAttributesReachTheSnapshot() throws {
    let snapshot = try snapshot(of: "\u{1B}[1mB\u{1B}[0m\u{1B}[3mI\u{1B}[0m\u{1B}[4mU\u{1B}[0m\u{1B}[7mV")
    #expect(snapshot[0, 0].flags.contains(.bold))
    #expect(snapshot[1, 0].flags.contains(.italic))
    #expect(snapshot[2, 0].flags.contains(.underline))
    #expect(snapshot[3, 0].flags.contains(.inverse))
    #expect(!snapshot[0, 0].flags.contains(.italic))
}

@Test func cursorPositionIsReported() throws {
    let snapshot = try snapshot(of: "\u{1B}[2;4H")
    let cursor = try #require(snapshot.cursor)
    #expect(cursor.column == 3)
    #expect(cursor.row == 1)
    #expect(cursor.style == .block)
}

@Test func hiddenCursorIsAbsentFromTheSnapshot() throws {
    // DECTCEM off. Drawing a cursor here would be a visible bug.
    #expect(try snapshot(of: "\u{1B}[?25l").cursor == nil)
}

@Test func barCursorStyleIsReported() throws {
    // DECSCUSR 6: steady bar.
    let cursor = try #require(try snapshot(of: "\u{1B}[6 q").cursor)
    #expect(cursor.style == .bar)
}

@Test func wideCharacterLeavesItsTrailingCellBlank() throws {
    // The glyph is drawn from the head cell and overhangs the tail; the tail must
    // carry no text of its own or it would be drawn twice.
    let snapshot = try snapshot(of: "日x")
    #expect(snapshot.text(of: snapshot[0, 0]) == "日")
    #expect(snapshot[1, 0].isBlank)
    #expect(snapshot.text(of: snapshot[2, 0]) == "x")
}

@Test func combiningMarkStaysInOneCell() throws {
    let frame = try snapshot(of: "e\u{0301}")
    #expect(frame.text(of: frame[0, 0]) == "é")
    #expect(frame[1, 0].isBlank)
}

@Test func sharedTextBufferIsResetBetweenFrames() throws {
    // The snapshot is reused across frames; stale bytes would accumulate forever.
    let core = try GhosttyTerminalCore(size: TerminalSize(columns: 10, rows: 3))
    let snapshot = RenderSnapshot()

    core.feed("aaaa")
    _ = try core.updateSnapshot(snapshot)
    let firstSize = snapshot.text.count

    core.feed("\u{1B}[2J\u{1B}[Hbbbb")
    _ = try core.updateSnapshot(snapshot)
    #expect(snapshot.text.count == firstSize)
    #expect(rowText(snapshot, 0) == "bbbb")
}

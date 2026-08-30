import Testing
import VitraCore
@testable import VitraGhostty

/// Feeds a string and returns the resulting viewport, trimmed of trailing blank lines.
private func render(
    _ input: String,
    size: TerminalSize = TerminalSize(columns: 20, rows: 5)
) throws -> [String] {
    let core = try GhosttyTerminalCore(size: size)
    core.feed(input)
    return core.screenText()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .reversed().drop(while: \.isEmpty).reversed()
        .map { $0 }
}

@Test func plainTextPassesThrough() throws {
    #expect(try render("hello") == ["hello"])
}

@Test func newlinesAdvanceRows() throws {
    #expect(try render("a\r\nb\r\nc") == ["a", "b", "c"])
}

@Test func sgrStylesDoNotLeakIntoText() throws {
    // The colour is state on the cell, not characters on the screen.
    #expect(try render("\u{1B}[31mRED\u{1B}[0m ok") == ["RED ok"])
}

@Test func cursorPositionSequencePlacesText() throws {
    // CUP to row 3, column 5.
    let lines = try render("\u{1B}[3;5Hx")
    #expect(lines.count == 3)
    #expect(lines[2] == "    x")
}

@Test func eraseInDisplayClearsScreen() throws {
    #expect(try render("garbage\u{1B}[2J\u{1B}[Hclean") == ["clean"])
}

@Test func wideCharactersOccupyTwoCells() throws {
    // Eight columns of CJK exactly fill a 16-column screen; a ninth wraps.
    let lines = try render(String(repeating: "日", count: 9), size: TerminalSize(columns: 16, rows: 4))
    #expect(lines.count == 2)
    #expect(lines[0] == String(repeating: "日", count: 8))
    #expect(lines[1] == "日")
}

@Test func combiningMarksStayOnOneCell() throws {
    let lines = try render("e\u{0301}!", size: TerminalSize(columns: 4, rows: 2))
    #expect(lines == ["e\u{0301}!"])
}

@Test func softWrapAtRightMargin() throws {
    #expect(try render("abcdef", size: TerminalSize(columns: 3, rows: 3)) == ["abc", "def"])
}

@Test func resizeReflowsWrappedContent() throws {
    let core = try GhosttyTerminalCore(size: TerminalSize(columns: 4, rows: 4))
    core.feed("abcdefgh")
    #expect(core.screenText().hasPrefix("abcd\nefgh"))

    try core.resize(to: TerminalSize(columns: 8, rows: 4))
    #expect(core.screenText().hasPrefix("abcdefgh"))
    #expect(core.size.columns == 8)
}

@Test func deviceStatusReportIsAnsweredThroughWritePTY() throws {
    // Programs that probe the terminal hang forever if these go unanswered, so
    // the callback plumbing matters more than it looks.
    let core = try GhosttyTerminalCore(size: TerminalSize(columns: 20, rows: 5))
    let replies = Replies()
    core.onWritePTY = { replies.append($0) }

    core.feed("\u{1B}[3;7H\u{1B}[6n")

    #expect(replies.joined == "\u{1B}[3;7R")
}

@Test func titleCallbackFiresForOSC0() throws {
    let core = try GhosttyTerminalCore(size: TerminalSize(columns: 20, rows: 5))
    let titles = Titles()
    core.onTitleChanged = { titles.append($0) }

    core.feed("\u{1B}]0;my title\u{07}")

    #expect(titles.all == ["my title"])
}

@Test func bellCallbackFires() throws {
    let core = try GhosttyTerminalCore(size: TerminalSize(columns: 20, rows: 5))
    let count = Counter()
    core.onBell = { count.increment() }

    core.feed("a\u{07}b\u{07}")

    #expect(count.value == 2)
}

@Test func scrollbackRetainsScrolledOffLines() throws {
    // Two rows of screen, three rows of output: "one" is pushed into scrollback
    // and must still be there. screenText() spans scrollback, so it sees all three.
    let core = try GhosttyTerminalCore(size: TerminalSize(columns: 8, rows: 2))
    core.feed("one\r\ntwo\r\nthree")
    #expect(core.screenText() == "one\ntwo\nthree")
}

// Callbacks fire synchronously inside feed(), but they are typed @Sendable, so
// these boxes give the closures something concurrency-safe to write into.
private final class Replies: @unchecked Sendable {
    private var chunks: [String] = []
    func append(_ bytes: UnsafeRawBufferPointer) {
        chunks.append(String(decoding: bytes, as: UTF8.self))
    }
    var joined: String { chunks.joined() }
}

private final class Titles: @unchecked Sendable {
    private(set) var all: [String] = []
    func append(_ title: String) { all.append(title) }
}

private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}

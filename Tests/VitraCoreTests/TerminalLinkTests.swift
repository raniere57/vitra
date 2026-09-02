import Foundation
import Testing
@testable import VitraCore

private func row(_ text: String, width: Int = 80) -> [Character] {
    Array(text) + Array(repeating: " ", count: max(0, width - text.count))
}

@Test func aUrlUnderThePointerIsFound() throws {
    let line = row("see https://claude.ai/code for more")
    let match = try #require(TerminalLink.match(in: line, at: 10))

    #expect(match.url.absoluteString == "https://claude.ai/code")
    #expect(match.columns == 4 ... 25)
}

@Test func plainWordsAreNotLinks() {
    #expect(TerminalLink.match(in: row("just some text"), at: 6) == nil)
}

@Test func blankColumnsAreNotLinks() {
    #expect(TerminalLink.match(in: row("https://x.dev"), at: 40) == nil)
}

@Test func aSentenceFullStopStaysOutOfTheLink() throws {
    let match = try #require(TerminalLink.match(in: row("read https://x.dev/a."), at: 12))
    #expect(match.url.absoluteString == "https://x.dev/a")
}

@Test func aBracketTheLinkOpenedIsKept() throws {
    let match = try #require(TerminalLink.match(in: row("https://en.wikipedia.org/wiki/Ruby_(gem)"), at: 5))
    #expect(match.url.absoluteString == "https://en.wikipedia.org/wiki/Ruby_(gem)")
}

@Test func aBracketTheLinkNeverOpenedIsDropped() throws {
    let match = try #require(TerminalLink.match(in: row("(https://x.dev/a)"), at: 8))
    #expect(match.url.absoluteString == "https://x.dev/a")
}

@Test func aBareHostWithWwwCountsAsALink() throws {
    let match = try #require(TerminalLink.match(in: row("try www.claude.ai now"), at: 6))
    #expect(match.url.absoluteString == "https://www.claude.ai")
}

@Test func aSchemeWithNothingAfterItIsNotALink() {
    #expect(TerminalLink.match(in: row("https://"), at: 2) == nil)
}

@Test func aFileUrlIsALink() throws {
    let match = try #require(TerminalLink.match(in: row("file:///Users/me/notes.md"), at: 3))
    #expect(match.url.isFileURL)
}

// MARK: - Paths

private let home = URL(fileURLWithPath: NSHomeDirectory())
private let project = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

@Test func anAbsolutePathIsALink() throws {
    let match = try #require(TerminalLink.match(in: row("wrote /tmp/out/shot.png ok"), at: 12))
    #expect(match.url.path == "/tmp/out/shot.png")
    #expect(match.columns == 6 ... 22)
}

@Test func aTildePathExpandsToHome() throws {
    let match = try #require(TerminalLink.match(in: row("see ~/notes.md"), at: 6))
    #expect(match.url.path == home.appendingPathComponent("notes.md").path)
}

@Test func aRelativePathNeedsABase() throws {
    #expect(TerminalLink.match(in: row("edit src/App.swift"), at: 8) == nil)
    let match = try #require(TerminalLink.match(in: row("edit src/App.swift"), at: 8, base: project))
    #expect(match.url.path == "/tmp/project/src/App.swift")
}

@Test func aLineReferenceIsDropped() throws {
    let match = try #require(TerminalLink.match(in: row("src/App.swift:12:3: error"), at: 3, base: project))
    #expect(match.url.path == "/tmp/project/src/App.swift")
}

@Test func aBareNameWithAnExtensionCountsRelativeToTheBase() throws {
    let match = try #require(TerminalLink.match(in: row("open report.html now"), at: 7, base: project))
    #expect(match.url.path == "/tmp/project/report.html")
}

@Test func numbersAndFlagsAreNotPaths() {
    #expect(TerminalLink.match(in: row("pi is 3.14 here"), at: 7, base: project) == nil)
    #expect(TerminalLink.match(in: row("use --force/now"), at: 6, base: project) == nil)
    #expect(TerminalLink.match(in: row("a lone / slash"), at: 7, base: project) == nil)
}

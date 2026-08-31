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

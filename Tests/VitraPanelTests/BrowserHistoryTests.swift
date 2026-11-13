import Foundation
import Testing
@testable import VitraPanel

@Test func aVisitedPageGoesToTheTopAndIsNeverListedTwice() {
    let url = { (text: String) in URL(string: text)! }
    var entries = BrowserHistory.adding(url("https://github.com/a/b"), to: [])
    entries = BrowserHistory.adding(url("http://localhost:3000/"), to: entries)
    entries = BrowserHistory.adding(url("https://github.com/a/b"), to: entries)
    #expect(entries == ["https://github.com/a/b", "http://localhost:3000/"])
}

@Test func onlyPagesFromTheWebAreRememberedAndOnlySoMany() {
    // A local file or a blank page is not somewhere to go back to by typing.
    for text in ["file:///tmp/x.html", "about:blank", "data:text/html,hi"] {
        #expect(BrowserHistory.adding(URL(string: text)!, to: ["https://a.com/"]) == ["https://a.com/"])
    }
    let many = (0..<300).reduce(into: [String]()) { entries, number in
        entries = BrowserHistory.adding(URL(string: "https://a.com/\(number)")!, to: entries)
    }
    #expect(many.count == BrowserHistory.limit)
    #expect(many.first == "https://a.com/299")
}

@Test func anEntryIsShownAsItWouldBeTypedAndTypingItLeadsBackToIt() {
    // Shown without the scheme, so typing "git" completes to it; the scheme is
    // only dropped where the address bar would put the same one back.
    #expect(BrowserHistory.display("https://github.com/a/b") == "github.com/a/b")
    #expect(BrowserHistory.display("https://example.com/") == "example.com")
    #expect(BrowserHistory.display("http://localhost:3000/") == "localhost:3000")
    #expect(BrowserHistory.display("http://example.com/x") == "http://example.com/x")
    for entry in ["https://github.com/a/b?q=1#top", "https://example.com/", "http://localhost:3000/", "http://example.com/x"] {
        #expect(BrowserView.url(from: BrowserHistory.display(entry))?.absoluteString.trimmingSuffix("/") == entry.trimmingSuffix("/"))
    }
}

@Test func theHistorySurvivesBeingWrittenAndReadAndABrokenFileIsAnEmptyOne() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(BrowserHistory.load(from: file).isEmpty)
    BrowserHistory.record(URL(string: "https://a.com/x")!, in: file)
    BrowserHistory.record(URL(string: "https://b.com/")!, in: file)
    #expect(BrowserHistory.load(from: file) == ["https://b.com/", "https://a.com/x"])
    try Data("not json".utf8).write(to: file)
    #expect(BrowserHistory.load(from: file).isEmpty)
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

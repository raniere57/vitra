import AppKit
import Testing
@testable import VitraPanel

@Suite("The browser beyond showing a page")
struct BrowserChromeTests {
    @Test func aFramesRefsCarryTheFramesName() {
        #expect(BrowserScripts.prefixing(ref: "f2", in: "- e7 button \"Play\"") == "- f2e7 button \"Play\"")
        #expect(BrowserScripts.prefixing(ref: "f2", in: "(no visible interactive elements)") == "(no visible interactive elements)")
        let split = BrowserScripts.frameAndRef("f12e7")
        #expect(split?.frame == "f12")
        #expect(split?.ref == "e7")
        #expect(BrowserScripts.frameAndRef("e7") == nil)
        #expect(BrowserScripts.frameAndRef("fe7") == nil)
        #expect(BrowserScripts.frameAndRef("foo") == nil)
    }

    @MainActor
    @Test func aDownloadNeverOverwritesAndNeverLeavesTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/downloads")
        let taken: Set<String> = ["/tmp/downloads/relatorio.pdf", "/tmp/downloads/relatorio 2.pdf"]
        let free = BrowserChrome.destination(for: "relatorio.pdf", in: folder) { taken.contains($0) }
        #expect(free?.path == "/tmp/downloads/relatorio 3.pdf")
        let escaped = BrowserChrome.destination(for: "../../etc/passwd", in: folder) { _ in false }
        #expect(escaped?.path == "/tmp/downloads/passwd")
        #expect(BrowserChrome.destination(for: "", in: folder) { _ in false }?.lastPathComponent == "download")
    }
}

@MainActor
@Test func theToolsReachInsideAFrameFromAnotherOrigin() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-frame-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A data: document has an origin of its own: the page cannot script it.
    let inner = "data:text/html,<button onclick=this.textContent=String(42)>Play</button>"
    let page = folder.appendingPathComponent("page.html")
    try "<html><body><h1>Aula</h1><iframe src='\(inner)' width='300' height='100'></iframe></body></html>"
        .write(to: page, atomically: true, encoding: .utf8)

    // In a window, or the page has no size and nothing on it counts as visible.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = browser
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    defer { browser.prepareForRemoval() }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        browser.load(page) { done.resume(with: $0) }
    }
    var listing = ""
    for _ in 0 ..< 40 {
        listing = try await browser.snapshot()
        if listing.contains("frame f1") { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(listing.contains("frame f1"))
    let line = try #require(listing.split(separator: "\n").first { $0.contains("\"Play\"") })
    let ref = try #require(line.split(separator: " ").dropFirst().first.map(String.init))
    #expect(ref.hasPrefix("f1e"))
    _ = try await browser.click(ref: ref)
    #expect(try await browser.snapshot().contains("button \"42\""))
}

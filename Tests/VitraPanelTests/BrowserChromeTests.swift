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

/// A page taken off screen while an agent works in it must not be told it
/// is hidden: players and many apps stop when it is.
@MainActor
@Test func aBrowserOffScreenStaysVisibleToItsPage() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let lot = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView?.addSubview(lot)
    window.orderBack(nil)
    defer { window.orderOut(nil) }

    let panel = PreviewPanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    window.contentView?.addSubview(panel)
    panel.parkingLot = lot
    let browser = panel.browser(for: "maestro")
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        browser.load(URL(string: "about:blank")!) { done.resume(with: $0) }
    }
    panel.parkCurrentBrowser()
    #expect(browser.superview === lot)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(try await browser.evaluate("return document.visibilityState") as? String == "visible")

    // The same page out of the window is what the lot is there to avoid.
    browser.removeFromSuperview()
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(try await browser.evaluate("return document.visibilityState") as? String == "hidden")

    // Back on screen, it is the panel's again.
    _ = panel.browser(for: "maestro")
    #expect(browser.superview !== lot)
    panel.dropBrowser(for: "maestro")
}

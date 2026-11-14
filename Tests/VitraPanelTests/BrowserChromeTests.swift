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

/// A load overtaken by another — a restored tab's address, then an agent's
/// open — is not a failure for whoever waited on the first.
@MainActor
@Test func aLoadReplacedByAnotherDoesNotFailItsWaiter() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-replaced-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("a.html"), second = folder.appendingPathComponent("b.html")
    try "<h1>a</h1>".write(to: first, atomically: true, encoding: .utf8)
    try "<h1>b</h1>".write(to: second, atomically: true, encoding: .utf8)

    let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    defer { browser.prepareForRemoval() }
    let results = try await withCheckedThrowingContinuation { (done: CheckedContinuation<[Bool], Error>) in
        var answers: [Bool] = []
        let answer: (Result<Void, Error>) -> Void = { result in
            answers.append((try? result.get()) != nil)
            if answers.count == 2 { done.resume(returning: answers) }
        }
        browser.load(first, completion: answer)
        browser.load(second, completion: answer)
    }
    #expect(results == [true, true])
    #expect(browser.currentURL?.lastPathComponent == "b.html")
}

/// An expression runs once: whether it returns nothing, throws or rejects,
/// a second run would click or post twice.
@MainActor
@Test func anAgentsScriptRunsOnceAndItsErrorIsReported() async throws {
    let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    defer { browser.prepareForRemoval() }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        browser.load(URL(string: "about:blank")!) { done.resume(with: $0) }
    }
    _ = try await browser.evaluateUserScript("globalThis.runs = 0")
    #expect(try await browser.evaluateUserScript("void (globalThis.runs += 1)") == nil)
    for failing in ["(globalThis.runs += 1, null.x)", "(globalThis.runs += 1, Promise.reject(new Error('recusado')))"] {
        let failed = (try? await browser.evaluateUserScript(failing)) == nil
        #expect(failed)
    }
    #expect(try await browser.evaluateUserScript("globalThis.runs") as? Int == 3)
    // Statements still work, and run once too.
    #expect(try await browser.evaluateUserScript("globalThis.runs += 1; return globalThis.runs") as? Int == 4)
}

/// A page that did not load keeps its address, so Reload retries it and the
/// tab is saved with it.
@MainActor
@Test func aFailedLoadKeepsTheAddressThatFailed() async throws {
    let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    defer { browser.prepareForRemoval() }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        browser.load(URL(string: "about:blank")!) { done.resume(with: $0) }
    }
    // A high port nothing listens on (WebKit blocks low ones like 9 outright).
    let down = URL(string: "http://127.0.0.1:65531/")!
    let result = await withCheckedContinuation { (done: CheckedContinuation<Result<Void, Error>, Never>) in
        browser.load(down) { done.resume(returning: $0) }
    }
    #expect((try? result.get()) == nil)
    // Once the error page is up, the address is the one it settled on.
    for _ in 0 ..< 40 {
        let text = try? await browser.evaluate("return document.body ? document.body.innerText : ''") as? String
        if text?.contains("127.0.0.1:65531") == true { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(browser.currentURL == down)
}

/// A local page gets the style sheet beside it, as every generated report
/// expects.
@MainActor
@Test func aLocalPageLoadsWhatSitsBesideIt() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-assets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "h1 { color: rgb(1, 2, 3); }".write(to: folder.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
    let page = folder.appendingPathComponent("index.html")
    try "<html><head><link rel=stylesheet href=style.css></head><body><h1>Relatório</h1></body></html>"
        .write(to: page, atomically: true, encoding: .utf8)

    let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    defer { browser.prepareForRemoval() }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        browser.load(page) { done.resume(with: $0) }
    }
    let color = try await browser.evaluate("return getComputedStyle(document.querySelector('h1')).color") as? String
    #expect(color == "rgb(1, 2, 3)")
}

@Test func aFailurePageShowsTheAddressAndReasonAsTextNeverAsMarkup() {
    let page = BrowserScripts.failurePage(address: "http://x/<script>alert(1)</script>", reason: "A \"conexão\" foi <recusada> & pronto")
    #expect(!page.contains("<script>alert(1)</script>"))
    #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    #expect(page.contains("A &quot;conexão&quot; foi &lt;recusada&gt; &amp; pronto"))
}

/// A page an agent works in must never learn that nobody is looking: sites
/// pause videos and stop timers on blur and on being hidden.
@MainActor
@Test func aPageAlwaysBelievesItIsVisibleAndInFocus() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-focus-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let page = folder.appendingPathComponent("page.html")
    try """
    <html><body><h1 id="state">nada</h1><h2 id="events">quieto</h2><script>
    const note = () => { document.getElementById('events').textContent = 'pausou'; };
    window.addEventListener('blur', note);
    window.onblur = note;
    document.addEventListener('visibilitychange', note);
    setInterval(() => { document.getElementById('state').textContent = document.hasFocus() + ' ' + document.visibilityState + ' ' + document.hidden; }, 50);
    </script></body></html>
    """.write(to: page, atomically: true, encoding: .utf8)

    // A window that is not key, with the browser then taken out of it: as
    // unfocused and as hidden as a page gets.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = browser
    window.orderBack(nil)
    defer { window.orderOut(nil); browser.prepareForRemoval() }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        browser.load(page) { done.resume(with: $0) }
    }
    _ = try await browser.evaluate("window.dispatchEvent(new Event('blur')); document.dispatchEvent(new Event('visibilitychange')); return 1")
    try await Task.sleep(nanoseconds: 300_000_000)
    let listing = try await browser.snapshot()
    #expect(listing.contains("\"true visible false\""))
    #expect(listing.contains("\"quieto\""))
}

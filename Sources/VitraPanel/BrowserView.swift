import AppKit
import VitraCore
import WebKit

/// The browser tab: an address bar, the usual controls, and a `WKWebView` that
/// an agent can drive.
///
/// Automation runs in an isolated content world. The page cannot see the
/// registry of element refs, cannot redefine the functions used to click, and
/// cannot read anything the agent evaluates.
public final class BrowserView: NSView, PreviewContentView, WKNavigationDelegate, WKScriptMessageHandler {
    /// Where automation runs: same DOM, separate JavaScript globals.
    private static let world = WKContentWorld.world(name: "vitra")

    /// Console lines kept for `browser_console`. Oldest first.
    private static let consoleLimit = 200

    /// Most elements a snapshot will list before saying it stopped.
    private static let snapshotLimit = 200

    public private(set) var console: [String] = []

    /// What the panel header should say.
    public var onPageChanged: ((_ title: String, _ url: String) -> Void)?

    private var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private let address = NSTextField()
    private let progress = NSProgressIndicator()
    private var pendingLoads: [(Result<Void, Error>) -> Void] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.surface.cgColor
        buildToolbar()
        buildWebView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Navigation

    public var currentURL: URL? { webView?.url }
    public var currentTitle: String { webView?.title ?? "" }

    /// Loads `url` and calls back when the page has finished, or failed.
    public func load(_ url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let webView else {
            completion(.failure(ToolFailure("the browser is not open")))
            return
        }
        address.stringValue = url.absoluteString
        console.removeAll()
        pendingLoads.append(completion)

        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    public func goBack() { webView?.goBack() }
    public func goForward() { webView?.goForward() }
    public func reload() { webView?.reload() }

    // MARK: - Automation

    /// Runs `script` in the isolated world and returns whatever it returns.
    public func evaluate(_ script: String) async throws -> Any? {
        guard let webView else { throw ToolFailure("the browser is not open") }
        do {
            return try await webView.callAsyncJavaScript(
                script,
                contentWorld: Self.world
            )
        } catch {
            throw ToolFailure("JavaScript failed: \(error.localizedDescription)")
        }
    }

    /// An expression or a block of statements, whichever the caller wrote.
    public func evaluateUserScript(_ script: String) async throws -> Any? {
        // `callAsyncJavaScript` runs a function body, so a bare expression has
        // to be returned explicitly. Statements are tried when that does not
        // parse, which is what makes both `1 + 1` and `let x = 1; return x` work.
        if let value = try? await evaluate("return (\(script))") { return value }
        return try await evaluate(script)
    }

    public func snapshot() async throws -> String {
        let raw = try await evaluate(BrowserScripts.snapshot(limit: Self.snapshotLimit))
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ToolFailure("the page did not answer") }

        let url = parsed["url"] as? String ?? ""
        let title = parsed["title"] as? String ?? ""
        let elements = parsed["elements"] as? [String] ?? []
        let truncated = parsed["truncated"] as? Bool ?? false

        var lines = ["url: \(url)", "title: \(title)", ""]
        lines.append(contentsOf: elements)
        if elements.isEmpty { lines.append("(no visible interactive elements)") }
        if truncated {
            lines.append("")
            lines.append("Stopped at \(Self.snapshotLimit) elements; the page has more.")
        }
        return lines.joined(separator: "\n")
    }

    public func click(ref: String) async throws -> String {
        let result = try await outcome(of: BrowserScripts.click(ref: ref), ref: ref)
        let role = result["role"] as? String ?? "element"
        let label = result["label"] as? String ?? ""
        return label.isEmpty ? "clicked \(ref) (\(role))" : "clicked \(ref) (\(role) \"\(label)\")"
    }

    public func type(ref: String, text: String, submit: Bool) async throws -> String {
        _ = try await outcome(of: BrowserScripts.type(ref: ref, text: text, submit: submit), ref: ref)
        return submit ? "typed into \(ref) and submitted" : "typed into \(ref)"
    }

    /// Runs a script that answers `{ok: …}` and turns a dead ref into a clear error.
    private func outcome(of script: String, ref: String) async throws -> [String: Any] {
        let raw = try await evaluate(script)
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ToolFailure("the page did not answer") }

        if parsed["ok"] as? Bool != true {
            let reason = parsed["reason"] as? String ?? "gone"
            if reason == "not-editable" {
                let role = parsed["role"] as? String ?? "element"
                throw ToolFailure("\(ref) is a \(role), which cannot be typed into.")
            }
            throw ToolFailure("\(ref) is no longer on the page. Take a new snapshot and use the new ref.")
        }
        return parsed
    }

    /// Writes a PNG of the visible page and returns where it went.
    public func screenshot(into store: AttachmentStore) async throws -> URL {
        guard let webView else { throw ToolFailure("the browser is not open") }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true

        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { throw ToolFailure("the page could not be captured") }

        return try store.store(png, extension: "png", prefix: "page")
    }

    public func clearConsole() { console.removeAll() }

    // MARK: - Lifecycle

    public func prepareForRemoval() {
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "vitraConsole")
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        web.removeFromSuperview()
        webView = nil
        finishLoads(with: .failure(ToolFailure("the browser was closed")))
    }

    deinit { webView?.removeFromSuperview() }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        address.stringValue = webView.url?.absoluteString ?? ""
        progress.stopAnimation(nil)
        progress.isHidden = true
        onPageChanged?(webView.title ?? "", webView.url?.host ?? "")
        finishLoads(with: .success(()))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failLoad(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failLoad(error)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.isHidden = false
        progress.startAnimation(nil)
    }

    private func failLoad(_ error: Error) {
        progress.stopAnimation(nil)
        progress.isHidden = true
        finishLoads(with: .failure(ToolFailure(error.localizedDescription)))
    }

    private func finishLoads(with result: Result<Void, Error>) {
        let waiting = pendingLoads
        pendingLoads.removeAll()
        waiting.forEach { $0(result) }
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "vitraConsole",
              let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["text"] as? String
        else { return }

        console.append("[\(level)] \(text)")
        if console.count > Self.consoleLimit { console.removeFirst(console.count - Self.consoleLimit) }
    }

    // MARK: - Chrome

    private func buildWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let controller = configuration.userContentController
        controller.add(self, contentWorld: .page, name: "vitraConsole")
        controller.addUserScript(WKUserScript(
            source: BrowserScripts.consoleForwarder,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        controller.addUserScript(WKUserScript(
            source: BrowserScripts.registry,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.world
        ))

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        webView = web

        // The title and URL arrive after the navigation finishes, and change
        // again on their own in a single-page app.
        observations = [
            web.observe(\.title, options: [.new]) { [weak self] view, _ in
                self?.reportPage(view)
            },
            web.observe(\.url, options: [.new]) { [weak self] view, _ in
                self?.address.stringValue = view.url?.absoluteString ?? ""
                self?.reportPage(view)
            },
        ]
    }

    private func reportPage(_ web: WKWebView) {
        let title = web.title ?? ""
        let host = web.url?.host ?? (web.url?.isFileURL == true ? "local file" : "")
        onPageChanged?(title, host)
    }

    private func buildToolbar() {
        let back = navigationButton("chevron.left", action: #selector(backClicked))
        let forward = navigationButton("chevron.right", action: #selector(forwardClicked))
        let reloadButton = navigationButton("arrow.clockwise", action: #selector(reloadClicked))

        address.font = PanelStyle.monospaced(10.5)
        address.textColor = PanelStyle.primaryText
        address.backgroundColor = PanelStyle.surface
        address.drawsBackground = true
        address.isBordered = false
        address.focusRingType = .none
        address.placeholderString = "address"
        address.target = self
        address.action = #selector(addressEntered)
        address.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [back, forward, reloadButton, address])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = PanelStyle.hairline.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 33),

            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14),

            hairline.topAnchor.constraint(equalTo: row.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func navigationButton(_ symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = PanelStyle.secondaryText
        button.isBordered = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func backClicked() { goBack() }
    @objc private func forwardClicked() { goForward() }
    @objc private func reloadClicked() { reload() }

    @objc private func addressEntered() {
        guard let url = BrowserView.url(from: address.stringValue) else { return }
        load(url) { _ in }
    }

    /// Turns what someone typed into a URL, the way a browser bar does.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }
}

/// A failure an agent is meant to read.
public struct ToolFailure: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

import AppKit
import UniformTypeIdentifiers
import WebKit

/// What makes the panel a browser and not a page viewer: links that ask for
/// a new window, the page's own dialogs, choosing a file to upload, and
/// downloads. WebKit does none of these unless told how; without them a
/// "open in new tab" link, a confirm() and a file field all do nothing.
@MainActor
final class BrowserChrome: NSObject, WKUIDelegate, WKDownloadDelegate {
    /// A line for the page's console, which the agents read too.
    var onNote: ((String) -> Void)?
    private weak var host: NSView?

    init(host: NSView) { self.host = host }

    // MARK: - New windows

    /// The panel has one page per tab: a link or `window.open` that wants a
    /// window of its own opens in this one.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: - The page's dialogs

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        onNote?("[dialog] alert: \(message)")
        present(alert(message, from: frame, buttons: ["OK"])) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        onNote?("[dialog] confirm: \(message)")
        present(alert(message, from: frame, buttons: ["OK", "Cancelar"])) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        onNote?("[dialog] prompt: \(prompt)")
        let alert = alert(prompt, from: frame, buttons: ["OK", "Cancelar"])
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    private func alert(_ message: String, from frame: WKFrameInfo, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "A página diz" : "\(frame.securityOrigin.host) diz"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    /// As a sheet on the window the page is in; answered as "cancel" when
    /// the page is in no window, so the page's script is never left hanging.
    private func present(_ alert: NSAlert, then: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let window = host?.window else { return then(.cancel) }
        alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { then(response) } }
    }

    // MARK: - Choosing files to upload

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = host?.window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completionHandler(response == .OK ? panel.urls : nil) }
        }
    }

    // MARK: - Downloads

    /// Into the user's Downloads folder, under a name that is not taken.
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let destination = Self.destination(for: suggestedFilename)
        destinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        onNote?("[download] salvo em \(destinations[ObjectIdentifier(download)]?.path ?? "Downloads")")
        destinations[ObjectIdentifier(download)] = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        onNote?("[download] falhou: \(error.localizedDescription)")
        destinations[ObjectIdentifier(download)] = nil
    }

    private var destinations: [ObjectIdentifier: URL] = [:]

    /// Takes charge of a download WebKit started.
    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    static func destination(for suggested: String, in folder: URL? = nil, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL? {
        let folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let folder else { return nil }
        // A name from the network: only its last component, never a path.
        let name = (suggested as NSString).lastPathComponent.isEmpty ? "download" : (suggested as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension, kind = (name as NSString).pathExtension
        for attempt in 0 ..< 500 {
            let candidate = attempt == 0 ? name : (kind.isEmpty ? "\(base) \(attempt + 1)" : "\(base) \(attempt + 1).\(kind)")
            let url = folder.appendingPathComponent(candidate)
            if !exists(url.path) { return url }
        }
        return nil
    }
}

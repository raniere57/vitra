import AppKit
import VitraCore
import WebKit

/// HTML, SVG and anything else that needs a browser engine.
///
/// The `WKWebView` is created here and nowhere else, which is what keeps WebKit
/// out of the process until a web file is actually opened. `prepareForRemoval`
/// drops it: releasing the last reference is what makes the
/// `com.apple.WebKit.WebContent` process exit.
final class WebPreviewView: NSView, PreviewContentView {
    private var webView: WKWebView?

    init(target: PreviewTarget) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.surface.cgColor

        let configuration = WKWebViewConfiguration()
        // Nothing a previewed file does should survive it: no cookies, no cache,
        // no local storage left behind between previews.
        configuration.websiteDataStore = .nonPersistent()

        let web = WKWebView(frame: bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        webView = web

        // Read access is granted to the file alone, not its folder: a previewed
        // page can render itself but cannot walk the directory it came from.
        web.loadFileURL(target.url, allowingReadAccessTo: target.url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func prepareForRemoval() {
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.configuration.userContentController.removeAllUserScripts()
        web.removeFromSuperview()
        webView = nil
    }

    deinit { webView?.removeFromSuperview() }
}

import AppKit
import VitraCore
import UniformTypeIdentifiers
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

        // WebKit shows a video file at the video's own size, which for
        // anything shot upright is taller than the panel. Held to the panel
        // and letterboxed, the whole frame and the controls are in view.
        if UTType(filenameExtension: target.url.pathExtension)?.conforms(to: .audiovisualContent) == true {
            let fit = """
            const style = document.createElement('style');
            style.textContent = 'html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#111}' +
                'video{position:fixed;inset:0;width:100%!important;height:100%!important;object-fit:contain}';
            document.documentElement.appendChild(style);
            """
            configuration.userContentController.addUserScript(
                WKUserScript(source: fit, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }

        let web = WKWebView(frame: bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        // The web view paints its own background. Left transparent, a page that
        // sets none — most local pages a developer opens — would put its black
        // text straight on the panel's dark surface instead of on the white
        // every browser gives it.
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

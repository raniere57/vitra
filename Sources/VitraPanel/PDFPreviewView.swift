import AppKit
import PDFKit
import VitraCore

/// A PDF, page by page, with PDFKit doing the drawing and scrolling.
final class PDFPreviewView: PDFView, PreviewContentView {
    init?(target: PreviewTarget) {
        super.init(frame: .zero)
        guard let document = PDFDocument(url: target.url) else { return nil }

        self.document = document
        autoScales = true
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        backgroundColor = PanelStyle.surface
        pageShadowsEnabled = false
    }

    private var hasPositioned = false

    /// Continuous mode opens at the end of the document, and jumping to page one
    /// only sticks once the view has a size, which is here rather than in init.
    override func layout() {
        super.layout()
        guard !hasPositioned, bounds.height > 0, let first = document?.page(at: 0) else { return }
        hasPositioned = true
        go(to: first)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

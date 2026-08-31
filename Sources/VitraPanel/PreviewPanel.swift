import AppKit
import VitraCore

/// The side panel: a header, and whichever preview the current file needs.
///
/// The panel knows nothing about the terminal. It is handed a `PreviewTarget`
/// and reports back through `onClose`; everything else is the app's business.
public final class PreviewPanel: NSView {
    /// Called when the panel's own close control is used.
    public var onClose: (() -> Void)?

    /// What is on screen, if anything.
    public private(set) var target: PreviewTarget?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let contentContainer = NSView()
    private var content: (any PreviewContentView)?
    private var emptyState: NSView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.surface.cgColor
        buildHeader()
        buildContentContainer()
        showEmptyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Content

    /// Shows `target`, replacing whatever was there.
    public func show(_ target: PreviewTarget) {
        clearContent()
        self.target = target

        titleLabel.stringValue = target.displayName
        detailLabel.stringValue = Self.detail(for: target)
        toolTip = target.url.path

        let kind = PreviewKind(for: target.url)
        guard let view = Self.makeContent(kind: kind, target: target) else {
            showEmptyState(message: "No preview for \(target.displayName)")
            return
        }

        emptyState?.removeFromSuperview()
        emptyState = nil

        view.frame = contentContainer.bounds
        view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(view)
        content = view
    }

    /// The browser, already on screen or created now.
    ///
    /// Opening a file preview replaces it, which is what makes WebKit leave
    /// memory when the agent is finished with a page.
    public func browser() -> BrowserView {
        if let existing = content as? BrowserView { return existing }

        clearContent()
        emptyState?.removeFromSuperview()
        emptyState = nil

        let browser = BrowserView(frame: contentContainer.bounds)
        browser.autoresizingMask = [.width, .height]
        browser.onPageChanged = { [weak self] title, host in
            self?.titleLabel.stringValue = title.isEmpty ? "Browser" : title
            self?.detailLabel.stringValue = host
        }
        contentContainer.addSubview(browser)
        content = browser

        titleLabel.stringValue = "Browser"
        detailLabel.stringValue = ""
        return browser
    }

    /// The browser if it is what the panel is showing, otherwise nil.
    public var currentBrowser: BrowserView? { content as? BrowserView }

    /// Drops the current preview and everything it holds open.
    ///
    /// Called when the panel is hidden, so a web preview does not keep a WebKit
    /// content process alive behind a panel nobody can see.
    public func clearContent() {
        content?.prepareForRemoval()
        content?.removeFromSuperview()
        content = nil
        target = nil
        titleLabel.stringValue = ""
        detailLabel.stringValue = ""
        toolTip = nil
        showEmptyState()
    }

    private static func makeContent(kind: PreviewKind, target: PreviewTarget) -> (any PreviewContentView)? {
        switch kind {
        case .image: return ImagePreviewView(target: target)
        case .pdf: return PDFPreviewView(target: target)
        case .web: return WebPreviewView(target: target)
        case .text: return TextPreviewView(target: target)
        case .unsupported: return nil
        }
    }

    private static func detail(for target: PreviewTarget) -> String {
        let size = (try? target.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let type = target.url.pathExtension.isEmpty ? "file" : target.url.pathExtension.lowercased()
        return "\(type) · \(formatted)"
    }

    // MARK: - Chrome

    private func buildHeader() {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = PanelStyle.headerSurface.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = PanelStyle.hairline.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        titleLabel.font = PanelStyle.monospaced(11.5, weight: .medium)
        titleLabel.textColor = PanelStyle.primaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = PanelStyle.monospaced(10.5)
        detailLabel.textColor = PanelStyle.secondaryText
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let close = NSButton(title: "", target: self, action: #selector(closeClicked))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close preview")
        close.contentTintColor = PanelStyle.secondaryText
        close.isBordered = false
        close.bezelStyle = .inline
        close.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(titleLabel)
        header.addSubview(detailLabel)
        header.addSubview(close)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PanelStyle.headerHeight),

            hairline.topAnchor.constraint(equalTo: header.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),

            detailLabel.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func buildContentContainer() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor, constant: PanelStyle.headerHeight + 1),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// The panel with nothing open also documents how to open something.
    private func showEmptyState(message: String? = nil) {
        emptyState?.removeFromSuperview()

        let hint = NSTextField(wrappingLabelWithString: message ?? """
        Nothing open.

        vitra open report.html
        printf '\\033]7337;file=%s\\a' shot.png
        """)
        hint.font = PanelStyle.monospaced(10.5)
        hint.textColor = PanelStyle.secondaryText
        hint.alignment = .left
        hint.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -14),
            hint.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 18),
        ])
        emptyState = hint
    }

    @objc private func closeClicked() { onClose?() }
}

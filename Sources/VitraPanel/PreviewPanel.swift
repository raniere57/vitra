import AppKit
import VitraCore

/// The side panel: a header, and whichever preview the current file needs.
///
/// The panel knows nothing about the terminal. It is handed a `PreviewTarget`
/// and reports back through `onClose`; everything else is the app's business.
public final class PreviewPanel: NSView {
    /// Called when the panel's own close control is used.
    public var onClose: (() -> Void)?

    /// A folder was clicked in the file list. The panel does not follow it
    /// itself: the terminal decides where it is, and the list follows that.
    public var onDirectorySelected: ((URL) -> Void)?

    /// What is on screen, if anything.
    public private(set) var target: PreviewTarget?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private var titleLeading: NSLayoutConstraint?
    private var titleAfterBack: NSLayoutConstraint?
    /// The directory the file list is on, kept so `Back` has somewhere to go.
    private var listedDirectory: URL?
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
        // Keeping the directory is what leaves a way back: opening a file from
        // the list must not throw the list away.
        clearContent(keepingDirectory: true)
        self.target = target

        titleLabel.stringValue = target.displayName
        detailLabel.stringValue = Self.detail(for: target)
        toolTip = target.url.path

        syncBackButton()

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

    /// Lists a directory, replacing whatever the panel was showing.
    ///
    /// This is the panel's resting state once a terminal is open: the files of
    /// the folder that terminal is in, one click from being previewed.
    public func showFiles(in directory: URL) {
        listedDirectory = directory

        if let list = content as? FileListView {
            list.show(directory)
            updateFileHeader(list)
            return
        }

        clearContent(keepingDirectory: true)
        emptyState?.removeFromSuperview()
        emptyState = nil

        let list = FileListView(directory: directory)
        list.onOpenFile = { [weak self] url in
            guard let self else { return }
            // Resolution is the same gate the escape sequence goes through, so
            // a click on a socket or a dangling link cannot open anything.
            guard let target = PreviewTarget.resolve(path: url.path) else {
                self.showEmptyState(message: "No preview for \(url.lastPathComponent)")
                return
            }
            self.show(target)
        }
        // The list browses itself: a file list that only moves when a shell
        // agrees to move is a file list that stops working the moment
        // something is running in that shell.
        list.onOpenDirectory = { [weak self] url in
            self?.showFiles(in: url)
            self?.onDirectorySelected?(url)
        }
        list.frame = contentContainer.bounds
        list.autoresizingMask = [.width, .height]
        contentContainer.addSubview(list)
        content = list
        updateFileHeader(list)
    }

    /// Remembers a directory to go back to without listing it now.
    ///
    /// A file opened by the agent or by `vitra open` never went through the
    /// list, and it should still leave the panel one click from the folder the
    /// terminal is in.
    public func rememberDirectory(_ directory: URL) {
        listedDirectory = directory
        syncBackButton()
    }

    /// Re-reads the listed directory, for after a command that touched it.
    public func refreshFiles() {
        guard let list = content as? FileListView else { return }
        list.reload()
        updateFileHeader(list)
    }

    /// Whether the panel is showing the file list rather than a preview.
    public var isListingFiles: Bool { content is FileListView }

    private func updateFileHeader(_ list: FileListView) {
        target = nil
        titleLabel.stringValue = list.directory.lastPathComponent
        detailLabel.stringValue = list.summary
        toolTip = list.directory.path
        syncBackButton()
    }

    /// The arrow back to the file list, shown only when there is one to go to.
    private func syncBackButton() {
        let showsBack = listedDirectory != nil && !(content is FileListView)
        backButton.isHidden = !showsBack
        titleLeading?.isActive = !showsBack
        titleAfterBack?.isActive = showsBack
    }

    @objc private func backClicked() {
        guard let listedDirectory else { return }
        showFiles(in: listedDirectory)
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
        clearContent(keepingDirectory: false)
    }

    private func clearContent(keepingDirectory: Bool) {
        content?.prepareForRemoval()
        content?.removeFromSuperview()
        content = nil
        target = nil
        if !keepingDirectory { listedDirectory = nil }
        titleLabel.stringValue = ""
        detailLabel.stringValue = ""
        toolTip = nil
        syncBackButton()
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

        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to files")
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.contentTintColor = PanelStyle.secondaryText
        backButton.isBordered = false
        backButton.bezelStyle = .inline
        backButton.toolTip = "Back to the file list"
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "", target: self, action: #selector(closeClicked))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close preview")
        close.contentTintColor = PanelStyle.secondaryText
        close.isBordered = false
        close.bezelStyle = .inline
        close.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(backButton)
        header.addSubview(titleLabel)
        header.addSubview(detailLabel)
        header.addSubview(close)

        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12)
        titleAfterBack = titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 6)
        titleLeading?.isActive = true

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PanelStyle.headerHeight),

            hairline.topAnchor.constraint(equalTo: header.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 16),

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

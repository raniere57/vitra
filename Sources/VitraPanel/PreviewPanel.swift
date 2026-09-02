import AppKit
import VitraCore

/// The side panel: a header, and whichever preview the current file needs.
///
/// The panel knows nothing about the terminal. It is handed a `PreviewTarget`
/// and reports back through `onClose`; everything else is the app's business.
public final class PreviewPanel: NSView {
    /// Called when the panel's own close control is used.
    public var onClose: (() -> Void)?

    /// The zoom button: the same thing double-clicking the divider and Escape
    /// do, for the hands that are on the mouse.
    public var onToggleMaximize: (() -> Void)?

    /// Whether the panel has the whole window, which turns the button's
    /// brackets inward and its tooltip into the way back.
    public var isMaximized = false {
        didSet {
            guard isMaximized != oldValue else { return }
            zoomButton.image = NSImage(
                systemSymbolName: isMaximized
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: zoomTip
            )
            zoomButton.toolTip = zoomTip
        }
    }

    private var zoomTip: String {
        isMaximized ? "Give the terminal its space back (esc)" : "Give the panel the whole window"
    }

    private let zoomButton = NSButton()

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
    /// The directory the file list is on, kept so `Back` has somewhere to go
    /// when nothing was browsed to yet — a file the agent opened first thing.
    private var listedDirectory: URL?

    /// Where the panel has been: folders browsed and files opened, in order.
    /// `Back` walks this, so it returns to the folder you were actually in,
    /// not to wherever the shell happens to be.
    private enum Stop: Equatable {
        case files(URL)
        case file(PreviewTarget)
    }
    private var history: [Stop] = []
    /// What is on screen, when it is one of the stops. Nil for the browser.
    private var current: Stop?
    private static let historyLimit = 50

    private let revealButton = NSButton()
    private let openButton = NSButton()
    private let copyPathButton = NSButton()
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
        record(.file(target))
        present(target)
    }

    private func present(_ target: PreviewTarget) {
        // Keeping the directory is what leaves a way back: opening a file from
        // the list must not throw the list away.
        clearContent(keepingDirectory: true)
        self.target = target
        current = .file(target)

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
        record(.files(directory))
        present(directory)
    }

    private func present(_ directory: URL) {
        listedDirectory = directory
        current = .files(directory)

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
        // Only when nothing has been browsed to: the shell moving on is no
        // reason to forget the folder the user dug down to.
        guard listedDirectory == nil else { return }
        listedDirectory = directory
        syncBackButton()
    }

    private func record(_ stop: Stop) {
        guard history.last != stop else { return }
        history.append(stop)
        if history.count > Self.historyLimit { history.removeFirst() }
    }

    /// The stop `Back` would go to, or nil when there is none.
    private var previousStop: Stop? {
        var stops = history
        if let current, stops.last == current { stops.removeLast() }
        if let last = stops.last { return last }
        // Nothing browsed, but a folder to fall back on — unless it is what is
        // already on screen.
        if let listedDirectory, !(content is FileListView) { return .files(listedDirectory) }
        return nil
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
        let showsBack = previousStop != nil
        backButton.isHidden = !showsBack
        titleLeading?.isActive = !showsBack
        titleAfterBack?.isActive = showsBack
        syncActionButtons()
    }

    @objc private func backClicked() {
        guard let previous = previousStop else { return }
        if let current, history.last == current { history.removeLast() }
        switch previous {
        case .files(let directory): present(directory)
        case .file(let target): present(target)
        }
    }

    // MARK: - Header actions

    /// The path the header's actions are about: the file shown, or the folder
    /// listed.
    private var actionURL: URL? {
        target?.url ?? (content is FileListView ? listedDirectory : nil)
    }

    private func syncActionButtons() {
        let hidden = actionURL == nil
        revealButton.isHidden = hidden
        copyPathButton.isHidden = hidden
        // Opening a folder in its default app is Finder again.
        openButton.isHidden = target == nil
    }

    @objc private func revealClicked() {
        guard let url = actionURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openClicked() {
        guard let url = target?.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyPathClicked() {
        guard let url = actionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// The browser, already on screen or created now.
    ///
    /// Opening a file preview replaces it, which is what makes WebKit leave
    /// memory when the agent is finished with a page.
    public func browser() -> BrowserView {
        if let existing = content as? BrowserView { return existing }

        // Keeping the history: the browser is a detour, and the back arrow
        // should still lead to the file or folder it interrupted.
        clearContent(keepingDirectory: true)
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
        current = nil
        if !keepingDirectory {
            listedDirectory = nil
            history.removeAll()
        }
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

        // Three small actions on whatever is shown: where it is, open it
        // properly, take its path. Hidden until there is a file or folder.
        configureAction(revealButton, "folder", "Reveal in Finder", #selector(revealClicked))
        configureAction(openButton, "arrow.up.forward.app", "Open in the default app", #selector(openClicked))
        configureAction(copyPathButton, "doc.on.doc", "Copy path", #selector(copyPathClicked))
        configureAction(
            zoomButton, "arrow.up.left.and.arrow.down.right", "Give the panel the whole window",
            #selector(zoomClicked)
        )
        zoomButton.isHidden = false
        let actions = NSStackView(views: [revealButton, openButton, copyPathButton, zoomButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(backButton)
        header.addSubview(titleLabel)
        header.addSubview(detailLabel)
        header.addSubview(actions)
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

            detailLabel.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            actions.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func configureAction(_ button: NSButton, _ symbol: String, _ tip: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.target = self
        button.action = action
        button.contentTintColor = PanelStyle.secondaryText
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = tip
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
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
    @objc private func zoomClicked() { onToggleMaximize?() }
}

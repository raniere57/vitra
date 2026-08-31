import AppKit
import Metal
import VitraCore
import VitraGhostty
import VitraPanel

/// One window, holding a tree of split terminal panes.
///
/// The split tree is the view hierarchy itself: splitting a pane wraps it in an
/// `NSSplitView` in place. There is no parallel model to keep in sync, and
/// closing a pane collapses the tree by walking back up the same hierarchy.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    private let device: MTLDevice
    private let fontName: String
    private let fontSize: CGFloat
    private let command: [String]?
    private let attachments: AttachmentStore

    /// Panes still alive in this window, in creation order.
    private var panes: [TerminalView] = []

    /// Holds the split tree of panes. Everything about splitting happens inside
    /// this view, so opening the preview panel never disturbs the pane
    /// hierarchy — the panel is added beside the container, not around a pane.
    private let paneContainer = NSView()

    /// Built the first time the panel is opened, and kept afterwards.
    private var panel: PreviewPanel?
    private var panelSplit: NSSplitView?

    /// The window's permanent content view.
    ///
    /// Everything else lives inside it, so a translucent window can keep a
    /// blur layer underneath while the panel comes and goes above.
    private let rootView = NSView()
    private var blurView: NSVisualEffectView?
    private var config: Config

    /// The title bar button that opens and closes the preview panel.
    private let panelButton = NSButton()

    /// The folder this window was opened for, if it came from a favourite.
    ///
    /// It survives for the life of the window because it is what the title, the
    /// accent stripe and every new pane here are derived from — a tab opened on
    /// a project stays that project's tab even after the shell wanders off.
    let bookmark: Bookmark?

    /// The title bar breadcrumb: where the focused shell is.
    private let pathLabel = NSTextField(labelWithString: "")

    /// The favourites down the left edge, and the folder tree beside them.
    private let sidebar = FolderSidebar()
    private var sidebarSplit: NSSplitView?
    /// The title bar buttons that open the sidebar on folders and on sessions.
    private let sidebarButton = NSButton()
    private let sessionsButton = NSButton()

    /// Everything right of the rail: the panes, and the panel when it is open.
    private let bodyView = NSView()

    init(
        device: MTLDevice,
        fontName: String,
        fontSize: CGFloat,
        command: [String]? = nil,
        attachments: AttachmentStore = AttachmentStore(),
        config: Config = Config(),
        bookmark: Bookmark? = nil
    ) throws {
        self.device = device
        self.bookmark = bookmark
        self.fontName = config.fontName
        self.fontSize = CGFloat(config.fontSize)
        // A folder's theme wins over the global one, which is the whole point of
        // setting it: the window that is on production should not look like the
        // window that is on a scratch directory.
        var windowConfig = config
        if let name = bookmark?.theme, let theme = Theme.named(name) {
            windowConfig.theme = theme
        }
        self.config = windowConfig
        self.command = command
        self.attachments = attachments

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 720, height: 460)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = bookmark.map { "\($0.emoji) \($0.name)" } ?? "Vitra"
        // Native window tabbing: macOS supplies the tab bar, Cmd-Shift-[ and ],
        // drag-between-windows, and the + button, none of which is worth
        // reimplementing.
        // The breadcrumb in the title bar already names the window, so the
        // centred title would be the same words twice. Tabs keep using
        // window.title, which is where that string is actually needed.
        window.titleVisibility = .hidden
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.vitra.terminal"
        window.center()

        super.init(window: window)

        let pane = try makePane()
        rootView.frame = window.contentLayoutRect
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        sidebar.onOpenBookmark = { bookmark in
            (NSApp.delegate as? AppDelegate)?.openTab(for: bookmark)
        }
        sidebar.onMenu = { [weak self] button in self?.showFolderMenu(button) }
        sidebar.onOpenDirectory = { [weak self] url, newTab in
            self?.openDirectory(url, newTab: newTab)
        }
        sidebar.onOpenSession = { [weak self] session in
            self?.openSession(session)
        }
        sidebar.onDismissSearch = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.focusedPane)
        }

        // A split rather than a fixed strip: the divider is how the sidebar is
        // expanded, so navigation is one drag away and stays whatever width the
        // user left it at.
        let split = PaneSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.frame = rootView.bounds
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(bodyView)
        split.delegate = self
        rootView.addSubview(split)
        sidebarSplit = split
        split.layoutSubtreeIfNeeded()
        split.setPosition(FolderSidebar.collapsedWidth, ofDividerAt: 0)

        paneContainer.frame = bodyView.bounds
        paneContainer.autoresizingMask = [.width, .height]
        pane.frame = paneContainer.bounds
        pane.autoresizingMask = [.width, .height]
        paneContainer.addSubview(pane)
        bodyView.addSubview(paneContainer)

        window.delegate = self
        window.makeFirstResponder(pane)
        installFolderControls(in: window)
        installWindowControls(in: window)
        apply(windowConfig)
        refreshRail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func togglePanelFromButton(_ sender: Any?) {
        togglePanel()
    }

    /// The folder chip and the split buttons, at the left of the title bar.
    ///
    /// Everything here is also a menu command and a shortcut. The buttons exist
    /// because a feature reachable only through a menu is a feature most people
    /// never find, and the folder chip doubles as the label saying which folder
    /// this window is.
    private func installFolderControls(in window: NSWindow) {
        // A breadcrumb, not a chip: the folder names the window, and the second
        // half says where the shell has since wandered — the question a terminal
        // with four panes actually raises.
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        makeIconButton(
            symbol: "sidebar.left",
            tooltip: "Folders sidebar (⌥⌘S)",
            action: #selector(toggleSidebarFromButton),
            button: sidebarButton,
            toggles: true
        )
        makeIconButton(
            symbol: "clock.arrow.circlepath",
            tooltip: "Claude Code sessions (⌥⌘C)",
            action: #selector(toggleSessionsFromButton),
            button: sessionsButton,
            toggles: true
        )

        let row = NSStackView(views: [makeCluster([sidebarButton, sessionsButton]), pathLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: 28)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = row
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
        updateBreadcrumb()
    }

    /// Splitting and the panel, as one segmented cluster at the right.
    ///
    /// Grouped into a single tinted well rather than scattered: three loose
    /// icons in a title bar read as clutter, one control reads as a control.
    private func installWindowControls(in window: NSWindow) {
        makeIconButton(
            symbol: "sidebar.right",
            tooltip: "Preview panel (⇧⌘P)",
            action: #selector(togglePanelFromButton),
            button: panelButton,
            toggles: true
        )
        let splitRight = makeIconButton(
            symbol: "square.split.2x1",
            tooltip: "Split right (⌘D)",
            action: #selector(splitRightFromButton)
        )
        let splitDown = makeIconButton(
            symbol: "square.split.1x2",
            tooltip: "Split down (⇧⌘D)",
            action: #selector(splitDownFromButton)
        )

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [makeCluster([splitRight, splitDown, separator, panelButton])])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        row.frame = NSRect(x: 0, y: 0, width: row.fittingSize.width, height: 28)
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 15),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = row
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// Redraws the sidebar from the app's current favourites.
    func refreshRail() {
        sidebar.update(
            bookmarks: (NSApp.delegate as? AppDelegate)?.bookmarks ?? [],
            current: bookmark?.id
        )
        sidebar.apply(config)
    }

    /// Expands the sidebar to the folder tree, or collapses it to the rail.
    func toggleSidebar() {
        show(.folders)
    }

    /// The same sidebar, showing the Claude Code sessions on this machine.
    func toggleSessions() {
        show(.sessions)
    }

    /// Opens the sidebar on `mode`, or closes it when it is already there.
    private func show(_ mode: FolderSidebar.Mode) {
        if sidebar.isExpanded, sidebar.mode == mode {
            setSidebar(expanded: false)
            return
        }
        sidebar.setMode(mode)
        setSidebar(expanded: true)
    }

    /// Resumes a session in the pane that has the keyboard.
    ///
    /// `--resume` only lists the sessions of the directory it runs in, so the
    /// directory is part of the line: the shell arrives where the session was.
    private func openSession(_ session: ClaudeSession) {
        guard let pane = focusedPane else { return }
        pane.session.send(text: ClaudeSessionStore.resumeCommand(for: session))
        window?.makeFirstResponder(pane)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshDirectory()
        }
    }

    private func setSidebar(expanded: Bool) {
        sidebar.setExpanded(expanded)
        sidebarSplit?.setPosition(
            expanded ? FolderSidebar.expandedWidth : FolderSidebar.collapsedWidth,
            ofDividerAt: 0
        )
        if expanded {
            sidebar.reveal(focusedPane?.session.currentDirectory)
            // Expanding deliberately is a request to find a folder, so the
            // filter field takes the keyboard; Escape hands it back.
            sidebar.focusSearch()
        }
        syncSidebarButton()
    }

    private func syncSidebarButton() {
        let onFolders = sidebar.isExpanded && sidebar.mode == .folders
        let onSessions = sidebar.isExpanded && sidebar.mode == .sessions
        sidebarButton.state = onFolders ? .on : .off
        sidebarButton.contentTintColor = onFolders ? .controlAccentColor : nil
        sessionsButton.state = onSessions ? .on : .off
        sessionsButton.contentTintColor = onSessions ? .controlAccentColor : nil
    }

    /// A folder was chosen in the sidebar or the file list.
    ///
    /// Without Cmd this is a `cd` typed into the terminal you are looking at —
    /// the shell moves, the sidebars follow it, and nothing new is opened.
    private func openDirectory(_ url: URL, newTab: Bool) {
        if newTab {
            (NSApp.delegate as? AppDelegate)?.openTab(
                for: Bookmark(name: url.lastPathComponent, path: url.path)
            )
            return
        }

        guard let pane = focusedPane else { return }
        pane.session.send(text: ShellQuote.changeDirectory(to: url.path))
        window?.makeFirstResponder(pane)
        // Shell integration reports the prompt coming back, which is the moment
        // the new directory is true. Without it nothing would report at all, so
        // one delayed read stands in — a single hop, not a running timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshDirectory()
        }
    }

    /// Points both sidebars at the folder the focused terminal is in.
    func refreshDirectory() {
        let directory = focusedPane?.session.currentDirectory
        updateBreadcrumb()
        sidebar.reveal(directory)
        if let directory, let panel {
            if panel.isListingFiles {
                panel.showFiles(in: directory)
            } else {
                // Not listing right now, but the back arrow should still lead
                // somewhere: the folder this terminal is in.
                panel.rememberDirectory(directory)
            }
        }
    }

    /// Shows where the focused shell is, relative to the window's folder.
    ///
    /// Driven by focus and title changes rather than a timer: a shell that
    /// changes directory says nothing, but it does redraw and retitle, and
    /// polling the kernel on a clock is the idle cost this app exists to avoid.
    private func updateBreadcrumb() {
        guard let directory = focusedPane?.session.currentDirectory else {
            pathLabel.stringValue = ""
            return
        }

        let path = directory.path
        if let root = bookmark?.url.path, path.hasPrefix(root) {
            let relative = String(path.dropFirst(root.count))
            pathLabel.stringValue = relative.isEmpty ? "" : "/" + relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            pathLabel.stringValue = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }

    /// Every title bar icon, at one size and one weight.
    ///
    /// The two clusters are built from this and nothing else: buttons that
    /// differ by a couple of points read as a mistake, and the eye finds it
    /// before it finds the icons.
    @discardableResult
    private func makeIconButton(
        symbol: String,
        tooltip: String,
        action: Selector,
        button: NSButton = NSButton(),
        toggles: Bool = false
    ) -> NSButton {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        if toggles { button.setButtonType(.pushOnPushOff) }
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    /// The tinted well the icons sit in, on both sides of the title bar.
    private func makeCluster(_ views: [NSView]) -> NSStackView {
        let cluster = NSStackView(views: views)
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 3
        cluster.edgeInsets = NSEdgeInsets(top: 2, left: 3, bottom: 2, right: 3)
        cluster.wantsLayer = true
        cluster.layer?.cornerRadius = 8
        cluster.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        return cluster
    }

    @objc private func toggleSidebarFromButton(_ sender: Any?) { toggleSidebar() }

    @objc private func toggleSessionsFromButton(_ sender: Any?) { toggleSessions() }

    @objc private func splitRightFromButton(_ sender: Any?) { splitFocusedPane(vertical: true) }
    @objc private func splitDownFromButton(_ sender: Any?) { splitFocusedPane(vertical: false) }

    /// The favourites, as a menu hanging off the chip.
    ///
    /// Built on each click rather than kept: the list changes whenever a folder
    /// is starred, and a stale menu is worse than no menu.
    @objc private func showFolderMenu(_ sender: NSButton) {
        let delegate = NSApp.delegate as? AppDelegate
        let menu = NSMenu()

        let goTo = menu.addItem(withTitle: "Go to Folder…", action: #selector(AppDelegate.showFolderPalette(_:)), keyEquivalent: "p")
        goTo.target = delegate
        let open = menu.addItem(withTitle: "New Tab in Folder…", action: #selector(AppDelegate.openFolderInNewTab(_:)), keyEquivalent: "")
        open.target = delegate
        let add = menu.addItem(withTitle: "Add Current Folder", action: #selector(AppDelegate.addCurrentFolder(_:)), keyEquivalent: "")
        add.target = delegate

        // No list of favourites here: the sidebar is the list now, one click
        // per folder whether it is collapsed to the rail or open on the tree.
        // A menu repeating it would be a second place to keep in sync.
        menu.addItem(.separator())
        let manage = menu.addItem(withTitle: "Manage Folders…", action: #selector(AppDelegate.showFolders(_:)), keyEquivalent: "")
        manage.target = delegate

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)

        // Opens filled: the whole screen minus the menu bar and the Dock, which
        // is the "Fill" the green button offers and not full screen — the menu
        // bar stays, other windows stay, and Mission Control is not involved.
        // A terminal is where the work happens; it should not open as a
        // eighty-by-twenty-four postcard that has to be resized first.
        if let window, let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
        }
    }

    // MARK: - Panes

    private func makePane() throws -> TerminalView {
        let size = TerminalSize(columns: 80, rows: 24)
        let core = try GhosttyTerminalCore(size: size)
        let executable = command?.first ?? config.shell ?? ShellEnvironment.loginShell()
        let session = try TerminalSession(
            core: core,
            executable: executable,
            arguments: command.map { Array($0.dropFirst()) } ?? ["-l"],
            environment: ShellEnvironment.childEnvironment(
                shell: executable,
                shellIntegration: config.shellIntegration,
                blockSpacing: config.blockSpacing,
                colorPrompt: config.colorPrompt,
                colorDefaults: config.colorDefaults
            ),
            size: size,
            workingDirectory: bookmark?.exists == true ? bookmark?.url.path : nil
        )
        let pane = try TerminalView(
            session: session,
            device: device,
            fontName: fontName,
            fontSize: fontSize,
            attachments: attachments
        )
        try? pane.apply(config)

        session.onTitleChanged = { [weak self, weak pane] title in
            guard let self, let pane, self.focusedPane === pane else { return }
            // The emoji stays whatever the shell reports: it is how this tab is
            // told apart from the other five, and the tab bar shows little else.
            let prefix = self.bookmark.map { "\($0.emoji) " } ?? ""
            self.window?.title = title.isEmpty ? (prefix.isEmpty ? "Vitra" : prefix.trimmingCharacters(in: .whitespaces)) : prefix + title
            self.refreshDirectory()
        }
        session.onBell = { NSSound.beep() }
        pane.onFocused = { [weak self] in self?.refreshDirectory() }
        session.onCommandStarted = { [weak pane] in
            pane?.commandStarted()
        }
        session.onCommandFinished = { [weak self, weak pane] status in
            // Already on main: the session hops for this callback.
            pane?.record(status)
            // A command that ended is the moment the working directory and the
            // files in it are settled — the only moment worth re-reading them.
            guard let self, let pane, self.focusedPane === pane else { return }
            self.refreshDirectory()
        }
        session.onPreviewRequest = { [weak self] target in
            // Arrives on the session's read queue; the panel is main-thread only.
            DispatchQueue.main.async { self?.preview(target) }
        }
        session.onExit = { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.close(pane)
        }

        panes.append(pane)
        // Only now, with every callback installed, is it safe to let output in.
        session.start()
        refreshFocusIndicators()
        return pane
    }

    /// Turns the focus border on once a window holds more than one pane.
    private func refreshFocusIndicators() {
        let many = panes.count > 1
        let tint = bookmark?.colorHex.flatMap { NSColor(hex: $0) } ?? .controlAccentColor
        panes.forEach {
            $0.focusTint = tint
            $0.showsFocusIndicator = many
        }
        updateBreadcrumb()
    }

    var focusedPane: TerminalView? {
        if let responder = window?.firstResponder as? TerminalView { return responder }
        return panes.last
    }

    /// Splits the focused pane, side by side or stacked.
    func splitFocusedPane(vertical: Bool) {
        guard let window, let pane = focusedPane else { return }

        // Where the pane sits has to be recorded before it is detached:
        // removing it from the container clears the relationship, so asking
        // afterwards gives the wrong answer.
        let wasRoot = pane.superview === paneContainer
        let parentSplit = pane.superview as? NSSplitView
        let indexInParent = parentSplit?.arrangedSubviews.firstIndex(of: pane)
        guard wasRoot || (parentSplit != nil && indexInParent != nil) else { return }

        let newPane: TerminalView
        do {
            newPane = try makePane()
        } catch {
            NSSound.beep()
            return
        }

        let split = PaneSplitView()
        // isVertical means the divider runs vertically, which puts the panes
        // side by side.
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.frame = pane.frame
        split.autoresizingMask = [.width, .height]

        pane.removeFromSuperview()
        pane.autoresizingMask = [.width, .height]
        newPane.autoresizingMask = [.width, .height]
        split.addArrangedSubview(pane)
        split.addArrangedSubview(newPane)

        if let parentSplit, let indexInParent {
            parentSplit.insertArrangedSubview(split, at: indexInParent)
            parentSplit.adjustSubviews()
        } else {
            split.frame = paneContainer.bounds
            paneContainer.addSubview(split)
        }

        // adjustSubviews() divides the space in proportion to what the subviews
        // already have, and the new pane starts at zero width, so it would stay
        // at zero. Placing the divider explicitly is what actually splits it.
        split.adjustSubviews()
        split.setPosition(
            (vertical ? split.bounds.width : split.bounds.height) / 2,
            ofDividerAt: 0
        )
        window.makeFirstResponder(newPane)
        refreshFocusIndicators()
    }

    /// Removes a pane and collapses any split that is left with a single child.
    func close(_ pane: TerminalView) {
        panes.removeAll { $0 === pane }
        pane.prepareForRemoval()
        refreshFocusIndicators()

        guard let window, let split = pane.superview as? NSSplitView else {
            // Last pane in the window: the window goes with it.
            window?.close()
            return
        }

        // Same ordering care as splitting: read the position first, detach after.
        let splitWasRoot = split.superview === paneContainer
        let parentSplit = split.superview as? NSSplitView
        let indexInParent = parentSplit?.arrangedSubviews.firstIndex(of: split)
        let frame = split.frame

        pane.removeFromSuperview()
        guard let survivor = split.arrangedSubviews.first else { return }

        // A split with one child left is just that child.
        survivor.removeFromSuperview()
        survivor.frame = frame
        survivor.autoresizingMask = [.width, .height]
        split.removeFromSuperview()

        if let parentSplit, let indexInParent {
            parentSplit.insertArrangedSubview(survivor, at: indexInParent)
            parentSplit.adjustSubviews()
        } else if splitWasRoot {
            survivor.frame = paneContainer.bounds
            paneContainer.addSubview(survivor)
        }

        window.makeFirstResponder(panes.first { $0.window != nil })
    }

    // MARK: - Preview panel

    /// Shows a file in the side panel, opening the panel if it is closed.
    func preview(_ target: PreviewTarget) {
        openPanel().show(target)
    }

    /// The browser in the side panel, opening the panel if it is closed.
    func browser() -> BrowserView {
        openPanel().browser()
    }

    /// `Cmd-Shift-P`: opens the panel, or closes it and releases its contents.
    func togglePanel() {
        if panel == nil { _ = openPanel() } else { closePanel() }
    }

    /// Keeps the title bar button showing whether the panel is open, however it
    /// was opened — a menu command, a dropped file or the agent.
    private func syncPanelButton() {
        panelButton.state = panel == nil ? .off : .on
        panelButton.contentTintColor = panel == nil ? nil : .controlAccentColor
    }

    @discardableResult
    private func openPanel() -> PreviewPanel {
        if let panel { return panel }

        let panel = PreviewPanel(frame: .zero)
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onDirectorySelected = { [weak self] url in self?.openDirectory(url, newTab: false) }
        if let directory = focusedPane?.session.currentDirectory {
            panel.showFiles(in: directory)
        }

        let split = PaneSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.frame = bodyView.bounds
        split.autoresizingMask = [.width, .height]

        paneContainer.removeFromSuperview()
        split.addArrangedSubview(paneContainer)
        split.addArrangedSubview(panel)
        split.delegate = self
        split.frame = bodyView.bounds
        bodyView.addSubview(split)

        // After layout: the split has no width of its own until the window has
        // sized it, and a divider placed before that collapses the terminal.
        split.layoutSubtreeIfNeeded()
        let width = split.bounds.width
        split.setPosition(max(width / 2, width - PanelStyle.defaultWidth), ofDividerAt: 0)

        self.panel = panel
        self.panelSplit = split
        syncPanelButton()
        return panel
    }

    private func closePanel() {
        guard let panel, let split = panelSplit else { return }
        // Releasing the content is the point: a web preview holds a WebKit
        // content process open until its view is dropped.
        panel.clearContent()
        panel.removeFromSuperview()

        paneContainer.removeFromSuperview()
        paneContainer.frame = split.frame
        paneContainer.autoresizingMask = [.width, .height]
        split.removeFromSuperview()
        bodyView.addSubview(paneContainer)

        self.panel = nil
        self.panelSplit = nil
        syncPanelButton()
        window?.makeFirstResponder(focusedPane)
    }

    func closeFocusedPane() {
        guard let pane = focusedPane else { return }
        pane.session.terminate()
    }

    // MARK: - Configuration

    /// Takes a new configuration: window translucency here, everything else in
    /// the panes.
    func apply(_ config: Config) {
        self.config = config
        guard let window else { return }

        let translucent = config.opacity < 1
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .black
        window.hasShadow = true

        if translucent && config.blur {
            if blurView == nil {
                let effect = NSVisualEffectView(frame: rootView.bounds)
                effect.material = .underPageBackground
                effect.blendingMode = .behindWindow
                effect.state = .active
                effect.autoresizingMask = [.width, .height]
                rootView.addSubview(effect, positioned: .below, relativeTo: nil)
                blurView = effect
            }
        } else {
            blurView?.removeFromSuperview()
            blurView = nil
        }

        sidebar.apply(config)

        for pane in panes {
            do {
                try pane.apply(config)
            } catch {
                NSSound.beep()
            }
        }
    }

    // MARK: - NSSplitViewDelegate

    /// The terminal keeps a usable width; the panel keeps a readable one.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        // The sidebar never goes narrower than the rail: collapsed is a state,
        // not a disappearance — the favourites stay reachable at every width.
        if splitView === sidebarSplit { return FolderSidebar.collapsedWidth }
        return max(proposed, 240)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === sidebarSplit { return min(proposed, 420) }
        return min(proposed, splitView.bounds.width - PanelStyle.minimumWidth)
    }

    /// Dragging the divider is what expands the sidebar, so the tree appears
    /// and disappears from the drag itself rather than from a second control.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === sidebarSplit else { return }
        let expanded = sidebar.frame.width > FolderSidebar.expansionThreshold
        guard expanded != sidebar.isExpanded else { return }
        sidebar.setExpanded(expanded)
        syncSidebarButton()
        if expanded { sidebar.reveal(focusedPane?.session.currentDirectory) }
    }

    /// A one-pixel divider is a one-pixel target. The drawn line stays thin and
    /// the draggable band around it is widened, which is the difference between
    /// a panel that resizes and a panel that looks fixed.
    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        drawnRect.insetBy(
            dx: splitView.isVertical ? -PanelStyle.dividerGrab : 0,
            dy: splitView.isVertical ? 0 : -PanelStyle.dividerGrab
        )
    }

    /// Growing the window gives the extra width to the terminal, which is what a
    /// side panel is expected to do.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== panel && view !== sidebar
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        panes.forEach { $0.updateBlinkTimer() }
        refreshDirectory()
    }

    func windowDidResignKey(_ notification: Notification) {
        panes.forEach { $0.updateBlinkTimer() }
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.prepareForRemoval() }
        panes.forEach { $0.session.terminate() }
        panes.removeAll()
    }
}


/// A split view whose divider is visible against a dark terminal, and whose
/// panes keep their proportions when it is resized.
///
/// The stock divider colour is chosen for light content and vanishes entirely on
/// a black background, leaving no way to see or grab the split. And the stock
/// resize takes the whole difference out of the first pane, which turns a 50/50
/// split into a sliver the moment the preview panel opens beside it.
private final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var dividerColor: NSColor { NSColor(white: 0.22, alpha: 1) }
    override var dividerThickness: CGFloat { 1 }

    /// Same widened grab band as the panel's divider: the line is a hairline,
    /// the target is not.
    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        drawnRect.insetBy(
            dx: splitView.isVertical ? -PanelStyle.dividerGrab : 0,
            dy: splitView.isVertical ? 0 : -PanelStyle.dividerGrab
        )
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let views = splitView.arrangedSubviews
        guard views.count > 1 else {
            splitView.adjustSubviews()
            return
        }

        let vertical = splitView.isVertical
        let dividers = splitView.dividerThickness * CGFloat(views.count - 1)
        let oldAvailable = (vertical ? oldSize.width : oldSize.height) - dividers
        let newAvailable = (vertical ? splitView.bounds.width : splitView.bounds.height) - dividers
        guard oldAvailable > 0, newAvailable > 0 else {
            splitView.adjustSubviews()
            return
        }

        let scale = newAvailable / oldAvailable
        let across = vertical ? splitView.bounds.height : splitView.bounds.width
        var offset: CGFloat = 0

        for (index, view) in views.enumerated() {
            let isLast = index == views.count - 1
            let current = vertical ? view.frame.width : view.frame.height
            // The last pane absorbs the rounding, so the panes always add up.
            let length = isLast ? newAvailable + dividers - offset : (current * scale).rounded()
            view.frame = vertical
                ? NSRect(x: offset, y: 0, width: length, height: across)
                : NSRect(x: 0, y: offset, width: across, height: length)
            offset += length + splitView.dividerThickness
        }
    }
}

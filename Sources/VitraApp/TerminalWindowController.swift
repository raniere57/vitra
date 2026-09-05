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
    /// The file list is showing a folder the terminal is not in, because the
    /// user browsed there while something was running.
    private var panelBrowsedAway = false

    /// The width the panes had before the panel took the whole window, and the
    /// monitor that watches for the Escape that gives it back.
    private var panelRestoreWidth: CGFloat?
    /// The pane holding the window on its own, and what it hid to get there.
    private var maximizedPane: TerminalView?
    private var hiddenForMaximize: [NSView] = []
    /// How the splits above the maximised pane were divided, as fractions, so
    /// coming back does not redistribute the window.
    private var maximizeProportions: [(split: NSSplitView, fractions: [CGFloat])] = []
    private var paneEscapeMonitor: Any?
    private var panelEscapeMonitor: Any?

    /// The window's permanent content view.
    ///
    /// Everything else lives inside it, so a translucent window can keep a
    /// blur layer underneath while the panel comes and goes above.
    private let rootView = NSView()
    private var blurView: NSVisualEffectView?
    private var config: Config

    /// The title bar button that opens and closes the preview panel.
    private let panelButton = TitleBarButton()

    /// The folder this window was opened for, if it came from a favourite.
    ///
    /// It survives for the life of the window because it is what the title, the
    /// accent stripe and every new pane here are derived from — a tab opened on
    /// a project stays that project's tab even after the shell wanders off.
    let bookmark: Bookmark?

    /// The title bar breadcrumb: where the focused shell is.
    private let pathLabel = NSTextField(labelWithString: "")

    /// The Claude Code session that pane is in, beside the breadcrumb.
    ///
    /// The sessions sidebar marks it too, but the sidebar is usually closed —
    /// and "which session is this window" is exactly the question you have when
    /// it is closed.
    private let sessionLabel = NSTextField(labelWithString: "")

    /// The favourites down the left edge, and the folder tree beside them.
    private let sidebar = FolderSidebar()
    private var sidebarSplit: NSSplitView?
    /// The title bar buttons that open the sidebar on folders and on sessions.
    private let sidebarButton = TitleBarButton()
    private let sessionsButton = TitleBarButton()
    private let openCodeButton = TitleBarButton()
    private let codexButton = TitleBarButton()

    /// Everything right of the rail: the panes, and the panel when it is open.
    private let bodyView = NSView()

    init(
        device: MTLDevice,
        fontName: String,
        fontSize: CGFloat,
        command: [String]? = nil,
        attachments: AttachmentStore = AttachmentStore(),
        config: Config = Config(),
        bookmark: Bookmark? = nil,
        /// A pane handed over by another window, instead of a new one.
        adopting: TerminalView? = nil
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

        let pane = try adopting ?? makePane()
        if adopting != nil { adopt(pane) }
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
        sidebar.onOpenRemote = { bookmark in
            (NSApp.delegate as? AppDelegate)?.openTab(for: bookmark)
        }
        sidebar.onSessionsLoaded = { [weak self] in
            self?.refreshDirectory()
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

    @objc private func openBrowserFromButton(_ sender: Any?) {
        browser().focusAddress()
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

        sessionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sessionLabel.textColor = .secondaryLabelColor
        sessionLabel.lineBreakMode = .byTruncatingTail
        sessionLabel.isHidden = true
        sessionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionLabel.maximumNumberOfLines = 1

        makeIconButton(
            symbol: "sidebar.left",
            tooltip: "Folders sidebar (⌥⌘S)",
            action: #selector(toggleSidebarFromButton),
            button: sidebarButton,
            toggles: true
        )
        makeIconButton(
            image: Harness.claudeCode.icon,
            tooltip: "Claude Code sessions (⌥⌘C)",
            action: #selector(toggleSessionsFromButton),
            button: sessionsButton,
            toggles: true
        )
        makeIconButton(
            image: Harness.openCode.icon,
            tooltip: "opencode sessions (⌥⌘O)",
            action: #selector(toggleOpenCodeFromButton),
            button: openCodeButton,
            toggles: true
        )
        makeIconButton(
            image: Harness.codex.icon,
            tooltip: "Codex sessions (⌥⌘X)",
            action: #selector(toggleCodexFromButton),
            button: codexButton,
            toggles: true
        )

        // Bare buttons on this side: no well around them, only the open one
        // lit. The well made the pair read as a single control with a smudge
        // in the middle.
        let row = NSStackView(views: [sidebarButton, sessionsButton, openCodeButton, codexButton, pathLabel, sessionLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.setCustomSpacing(10, after: codexButton)
        row.frame = NSRect(x: 0, y: 0, width: 520, height: 28)

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

        let browserButton = makeIconButton(
            symbol: "globe",
            tooltip: "Browser (⇧⌘B)",
            action: #selector(openBrowserFromButton)
        )

        let mergeButton = makeIconButton(
            symbol: "arrow.triangle.merge",
            tooltip: "Move these terminals into another tab",
            action: #selector(mergeIntoTabFromButton)
        )

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let mergeSeparator = NSBox()
        mergeSeparator.boxType = .separator
        mergeSeparator.translatesAutoresizingMaskIntoConstraints = false

        // Bare here too, same as the pair on the left: the hairline is enough
        // to say the splits and the panel are different jobs.
        let row = NSStackView(views: [
            mergeButton, mergeSeparator, splitRight, splitDown, separator, browserButton, panelButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.setCustomSpacing(8, after: mergeButton)
        row.setCustomSpacing(8, after: mergeSeparator)
        row.setCustomSpacing(8, after: splitDown)
        row.setCustomSpacing(8, after: separator)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        row.frame = NSRect(x: 0, y: 0, width: row.fittingSize.width, height: 28)
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 15),
            separator.widthAnchor.constraint(equalToConstant: 1),
            mergeSeparator.heightAnchor.constraint(equalToConstant: 15),
            mergeSeparator.widthAnchor.constraint(equalToConstant: 1),
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

    /// The same sidebar, showing one agent's sessions on this machine.
    func toggleSessions(_ harness: Harness = .claudeCode) {
        show(.sessions(harness))
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
    /// Types a command into the focused pane. Used when a tab opens to run one.
    ///
    /// `session` is the Claude Code session the command resumes, when it is
    /// one: the sidebar marks the pane that is in it.
    func run(_ command: String, session: String? = nil) {
        guard let pane = focusedPane else { return }
        pane.agentSession = session
        pane.session.send(text: command)
        window?.makeFirstResponder(pane)
        sidebar.setCurrentSession(session)
    }

    /// Opens a session in a pane of its own, beside whatever is already here.
    ///
    /// Never in the pane that has the keyboard: that pane is usually in a
    /// session of its own, and taking it over to open a second one loses the
    /// first. The new pane starts in the session's project, and the old one is
    /// left running for as long as the user wants it.
    private func openSession(_ session: AgentSession) {
        guard let pane = splitFocusedPane(vertical: true, in: session.projectPath) else {
            (NSApp.delegate as? AppDelegate)?.openTab(
                for: Bookmark(
                    name: URL(fileURLWithPath: session.projectPath).lastPathComponent,
                    path: session.projectPath
                ),
                running: session.resumeCommand,
                session: session.id
            )
            return
        }
        pane.agentSession = session.id
        // The shell has to be up to read what it is handed, the same hop a new
        // tab makes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak pane] in
            pane?.session.send(text: session.resumeCommand)
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
        let open = sidebar.isExpanded ? sidebar.mode : nil
        let states: [(TitleBarButton, Bool)] = [
            (sidebarButton, open == .folders),
            (sessionsButton, open == .sessions(.claudeCode)),
            (openCodeButton, open == .sessions(.openCode)),
            (codexButton, open == .sessions(.codex)),
        ]
        for (button, isOn) in states {
            button.state = isOn ? .on : .off
            button.contentTintColor = isOn ? .controlAccentColor : nil
            // The open one carries a tint behind its glyph: at twelve points a
            // recoloured icon alone is a detail you have to look for.
            tint(button, on: isOn)
        }
    }

    private func tint(_ button: TitleBarButton, on: Bool) {
        button.isLit = on
    }

    /// A folder was chosen in the sidebar or the file list.
    ///
    /// Without Cmd this is a `cd` typed into the terminal you are looking at —
    /// the shell moves, the sidebars follow it, and nothing new is opened.
    /// A link clicked in a pane: the panel by default, the browser on Command.
    ///
    /// The panel is the point - a link in a terminal is usually something to
    /// glance at, and glancing at it in the window it came from beats losing
    /// the window. Command is the escape hatch to a real browser.
    private func open(_ url: URL, external: Bool) {
        guard !external else {
            NSWorkspace.shared.open(url)
            return
        }
        // A file is a preview; anything else is a page.
        if url.isFileURL, let target = PreviewTarget.resolve(path: url.path) {
            preview(target)
            return
        }
        browser().load(url) { _ in }
    }

    /// Takes the terminal along with the file list, when it can be taken.
    ///
    /// Browsing the panel is not a request to run anything: a pane with a
    /// program in the foreground would read the `cd` as input, which is how it
    /// ended up in Claude Code's chat box. The list has already moved.
    private func followDirectory(_ url: URL) {
        guard let pane = focusedPane, !pane.session.isRunningProgram else {
            panelBrowsedAway = true
            return
        }
        panelBrowsedAway = false
        pane.session.send(text: ShellQuote.changeDirectory(to: url.path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshDirectory()
        }
    }

    private func openDirectory(_ url: URL, newTab: Bool) {
        // A busy pane cannot be sent a command, so the folder opens where it
        // can be opened: a tab of its own.
        if newTab || focusedPane?.session.isRunningProgram == true {
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
        sidebar.setCurrentSession(currentSession)
        if let directory, let panel {
            if panel.isListingFiles {
                // Browsed somewhere else on purpose while the pane was busy: a
                // redraw is no reason to drag the user back.
                if !panelBrowsedAway { panel.showFiles(in: directory) }
            } else {
                // Not listing right now, but the back arrow should still lead
                // somewhere: the folder this terminal is in.
                panel.rememberDirectory(directory)
            }
        }
    }

    /// The Claude Code session the focused pane is in, as far as it can be told.
    ///
    /// Told outright when the sidebar started it. Otherwise recognised: Claude
    /// Code names the terminal after the conversation, so a pane running a
    /// program in a folder that has sessions is matched to the one whose title
    /// the pane is wearing. That covers the sessions started by hand, resumed
    /// from inside Claude Code, or begun by a compaction — which is most of
    /// them, and all of the ones the mark was missing.
    private var currentSession: String? {
        guard let pane = focusedPane, pane.session.isRunningProgram else { return nil }
        if let explicit = pane.agentSession { return explicit }
        guard let harness = runningHarness(in: pane) else { return nil }
        return sidebar.session(
            named: pane.programTitle,
            in: pane.session.currentDirectory?.path,
            of: harness
        )
    }

    /// The agent a pane is running, by what holds its terminal — and, for
    /// Claude Code, by the title it wears: a pane running `claude` through a
    /// wrapper still says so in the title bar.
    private func runningHarness(in pane: TerminalView) -> Harness? {
        if let harness = Harness.running(pane.session.foregroundName) { return harness }
        return ClaudeSessionStore.isClaudeCode(pane.programTitle) ? .claudeCode : nil
    }

    /// Shows where the focused shell is, relative to the window's folder.
    ///
    /// Driven by focus and title changes rather than a timer: a shell that
    /// changes directory says nothing, but it does redraw and retitle, and
    /// polling the kernel on a clock is the idle cost this app exists to avoid.
    private func updateBreadcrumb() {
        pathLabel.stringValue = breadcrumb()
        updateSessionLabel()
    }

    /// The folder, then where the shell has wandered inside it.
    ///
    /// The folder is always named. It used to be left out whenever the shell
    /// was sitting in the window's own folder — the common case — on the
    /// grounds that the window was named elsewhere, which left the title bar
    /// saying nothing at all about the most useful thing it knows.
    private func breadcrumb() -> String {
        // A remote tab's local shell is sitting in the home directory while the
        // user is on another machine; the favourite is the honest answer.
        if let bookmark, bookmark.isRemote { return bookmark.displayPath }
        guard let directory = focusedPane?.session.currentDirectory else {
            return bookmark?.name ?? ""
        }

        let path = directory.path
        if let root = bookmark?.url.path, path.hasPrefix(root) {
            let name = bookmark?.name ?? (root as NSString).lastPathComponent
            let relative = String(path.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? name : "\(name)/\(relative)"
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Names the session the focused pane is in, or hides the label.
    private func updateSessionLabel() {
        // A pane wearing Claude Code's title is the reason to read the sessions
        // at all; the read answers on the main thread and comes back through
        // onSessionsLoaded, which lands here again with a title to show.
        let harness = focusedPane.flatMap(runningHarness(in:))
        if let harness { sidebar.loadSessions(harness) }
        else if focusedPane?.agentSession != nil { Harness.allCases.forEach(sidebar.loadSessions) }

        guard let id = currentSession, let title = sidebar.sessionTitle(of: id) else {
            sessionLabel.isHidden = true
            sessionLabel.stringValue = ""
            return
        }
        sessionLabel.stringValue = "\(harness?.marker ?? Harness.claudeCode.marker) \(title)"
        sessionLabel.toolTip = title
        sessionLabel.isHidden = false
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
        button: TitleBarButton = TitleBarButton(),
        toggles: Bool = false
    ) -> TitleBarButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        return makeIconButton(
            image: image,
            tooltip: tooltip,
            action: action,
            button: button,
            toggles: toggles
        )
    }

    /// The same button, for a mark this app draws itself.
    @discardableResult
    private func makeIconButton(
        image: NSImage?,
        tooltip: String,
        action: Selector,
        button: TitleBarButton = TitleBarButton(),
        toggles: Bool = false
    ) -> TitleBarButton {
        button.image = image
        button.image?.accessibilityDescription = tooltip
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
    @objc private func toggleSidebarFromButton(_ sender: Any?) { toggleSidebar() }

    @objc private func toggleSessionsFromButton(_ sender: Any?) { toggleSessions() }
    @objc private func toggleOpenCodeFromButton(_ sender: Any?) { toggleSessions(.openCode) }
    @objc private func toggleCodexFromButton(_ sender: Any?) { toggleSessions(.codex) }

    /// The list of tabs these terminals can be moved into.
    ///
    /// Dragging one tab onto another is AppKit's gesture and AppKit only ever
    /// reorders the strip with it, so the move is a menu: every other tab of
    /// this window group, named and counted, and the terminals of this tab go
    /// into the one that is picked.
    @objc private func mergeIntoTabFromButton(_ sender: NSButton) {
        let menu = NSMenu()
        let others = tabSiblings()
        if others.isEmpty {
            let empty = menu.addItem(withTitle: "No other tabs to move into", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        } else {
            let header = menu.addItem(
                withTitle: panes.count == 1 ? "Move this terminal to…" : "Move these \(panes.count) terminals to…",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(.separator())
            for controller in others {
                let item = menu.addItem(
                    withTitle: controller.tabDescription,
                    action: #selector(mergeIntoTab(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = controller
                if let symbol = controller.bookmark?.symbolName {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
                }
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// How a tab names itself in that list: the folder it was opened for, the
    /// title its shell reports, and how many terminals are already in it.
    var tabDescription: String {
        let name = window?.title.isEmpty == false ? window!.title : (bookmark?.name ?? "Terminal")
        let count = panes.count == 1 ? "1 terminal" : "\(panes.count) terminals"
        return "\(name) — \(count)"
    }

    /// The other tabs of this window's group.
    private func tabSiblings() -> [TerminalWindowController] {
        guard let window, let group = window.tabGroup else { return [] }
        return group.windows
            .filter { $0 !== window }
            .compactMap { $0.windowController as? TerminalWindowController }
    }

    @objc private func mergeIntoTab(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TerminalWindowController else { return }
        move(into: target)
    }

    /// Hands every terminal of this tab to another one, which ends this tab.
    ///
    /// Each pane is placed against the longer side of whatever it lands beside,
    /// so a tab of four terminals arriving in another does not turn into four
    /// slivers of a column.
    func move(into target: TerminalWindowController) {
        guard target !== self else { return }
        restorePanes()
        target.restorePanes()
        for pane in panes {
            guard let beside = target.focusedPane ?? target.panes.first else { break }
            target.accept(pane, beside: beside, on: target.edgeSplitting(beside))
        }
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// The side to put a new pane on: whichever cut leaves both halves closer to
    /// square.
    private func edgeSplitting(_ pane: TerminalView) -> PaneEdge {
        pane.bounds.width >= pane.bounds.height ? .trailing : .bottom
    }

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

    private func makePane(in directory: String? = nil) throws -> TerminalView {
        let size = TerminalSize(columns: 80, rows: 24)
        let core = try GhosttyTerminalCore(size: size)
        let executable = command?.first ?? config.shell ?? ShellEnvironment.loginShell()
        // Named before the shell starts, because the name goes in with it: an
        // agent's `vitra mcp` helper inherits it and sends it back on every
        // call, which is what gives each pane a browser of its own.
        let paneID = UUID().uuidString
        let session = try TerminalSession(
            core: core,
            executable: executable,
            arguments: command.map { Array($0.dropFirst()) } ?? ["-l"],
            environment: ShellEnvironment.childEnvironment(
                shell: executable,
                shellIntegration: config.shellIntegration,
                blockSpacing: config.blockSpacing,
                colorPrompt: config.colorPrompt,
                colorDefaults: config.colorDefaults,
                extra: ["VITRA_PANE": paneID]
            ),
            size: size,
            workingDirectory: directory ?? (bookmark?.exists == true ? bookmark?.url.path : nil)
        )
        let pane = try TerminalView(
            session: session,
            device: device,
            fontName: fontName,
            fontSize: fontSize,
            attachments: attachments
        )
        pane.paneID = paneID
        try? pane.apply(config)

        wire(pane)

        // Only now, with every callback installed, is it safe to let output in.
        session.start()
        return pane
    }

    /// Points a pane and its session at this window.
    ///
    /// Every callback is set here rather than where the pane is built, because
    /// a pane can change windows — moved to a tab of its own — and what it
    /// talks to has to change with it.
    private func wire(_ pane: TerminalView) {
        let session = pane.session
        session.onTitleChanged = { [weak self, weak pane] title in
            pane?.recordTitle(title)
            guard let self, let pane, self.focusedPane === pane else { return }
            // The emoji stays whatever the shell reports: it is how this tab is
            // told apart from the other five, and the tab bar shows little else.
            let prefix = self.bookmark.map { "\($0.emoji) " } ?? ""
            self.window?.title = title.isEmpty ? (prefix.isEmpty ? "Vitra" : prefix.trimmingCharacters(in: .whitespaces)) : prefix + title
            self.refreshDirectory()
        }
        session.onBell = { NSSound.beep() }
        pane.onFocused = { [weak self] in self?.refreshDirectory() }
        pane.onOpenLink = { [weak self] url, external in self?.open(url, external: external) }
        pane.onClose = { [weak self, weak pane] in
            guard let pane else { return }
            self?.close(pane)
        }
        pane.onToggleMaximized = { [weak self, weak pane] in
            guard let pane else { return }
            self?.toggleMaximized(pane)
        }
        pane.onMoveToNewTab = { [weak self, weak pane] in
            guard let pane else { return }
            self?.moveToNewTab(pane)
        }
        pane.onPaneDragMoved = { point in
            (NSApp.delegate as? AppDelegate)?.revealTab(under: point)
        }
        pane.onPaneDropped = { [weak self, weak pane] dropped, edge in
            guard let pane else { return }
            self?.accept(dropped, beside: pane, on: edge)
        }
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
        refreshFocusIndicators()
    }

    /// Whether this window holds that pane.
    func holds(_ pane: TerminalView) -> Bool { panes.contains { $0 === pane } }

    /// The pane an MCP call named, if it is one of this window's.
    func pane(withID id: String) -> TerminalView? { panes.first { $0.paneID == id } }

    /// Takes over a pane another window built, keeping its shell running.
    func adopt(_ pane: TerminalView) {
        wire(pane)
        try? pane.apply(config)
        syncMaximizeButtons()
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

    // MARK: - Layout

    /// What this window is showing, in the form the next launch can rebuild.
    func layout(tabGroup: Int, sessions: [AgentSession] = []) -> Layout.Window? {
        // A window with no panes left is one that has closed: nothing to save.
        guard let window, !panes.isEmpty, let root = paneContainer.subviews.first else { return nil }
        let frame = window.frame
        return Layout.Window(
            directory: bookmark?.path,
            frame: Layout.Frame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            ),
            sidebar: Layout.Sidebar(
                expanded: sidebar.isExpanded,
                mode: sidebar.mode.harness?.rawValue ?? "folders",
                width: sidebar.frame.width
            ),
            tabGroup: tabGroup,
            root: node(of: root, sessions: sessions)
        )
    }

    /// One view of the pane tree, as a node.
    ///
    /// The proportions come from the frames rather than from a divider index:
    /// what is on screen is the truth, and it survives a window that was
    /// resized after the last drag.
    private func node(of view: NSView, sessions: [AgentSession]) -> Layout.Node {
        guard let split = view as? NSSplitView else {
            guard let pane = view as? TerminalView else { return .pane(Layout.Pane()) }
            let directory = pane.session.currentDirectory?.path ?? bookmark?.path
            // The same recognition the sidebar's mark uses: most sessions were
            // never launched from the sidebar, and those are exactly the ones
            // worth reopening.
            let session = pane.agentSession ?? runningHarness(in: pane)?.matching(
                title: pane.programTitle,
                directory: directory,
                in: sessions
            )?.id
            return .pane(Layout.Pane(directory: directory, session: session))
        }

        let children = split.arrangedSubviews
        let sizes = children.map { split.isVertical ? $0.frame.width : $0.frame.height }
        let total = max(sizes.reduce(0, +), 1)
        return .split(
            vertical: split.isVertical,
            fractions: sizes.map { $0 / total },
            children: children.map { node(of: $0, sessions: sessions) }
        )
    }

    /// Rebuilds a saved pane tree in place of the single pane a new window has.
    func restore(_ window: Layout.Window) {
        // A single pane is what a new window already is: nothing to rebuild,
        // and rebuilding it would throw away the pane the window was born with.
        if case let .pane(saved) = window.root {
            // The window was born with one pane, in the folder it was opened on.
            // When the saved pane was somewhere else, it is walked there rather
            // than rebuilt: a fresh pane would lose the shell already running.
            if let directory = saved.directory, directory != bookmark?.path {
                focusedPane?.session.send(text: "cd " + ShellQuote.quote(directory) + "\n")
            }
            resume(saved, in: focusedPane)
        } else if let built = build(window.root) {
            for pane in panes where pane.superview === paneContainer { pane.prepareForRemoval() }
            panes.removeAll { $0.superview === paneContainer }
            paneContainer.subviews.forEach { $0.removeFromSuperview() }
            built.frame = paneContainer.bounds
            built.autoresizingMask = [.width, .height]
            paneContainer.addSubview(built)
            paneContainer.layoutSubtreeIfNeeded()
            place(window.root, in: built)
            self.window?.makeFirstResponder(panes.first)
        }
        syncMaximizeButtons()

        if window.sidebar.expanded {
            // "sessions" is what the old layouts called Claude Code's list.
            let saved = window.sidebar.mode == "sessions" ? Harness.claudeCode.rawValue : window.sidebar.mode
            sidebar.setMode(Harness(rawValue: saved).map(FolderSidebar.Mode.sessions) ?? .folders)
            setSidebar(expanded: true)
        }
        refreshFocusIndicators()
        refreshDirectory()
    }

    /// Builds the views for a saved tree. Nil when a pane cannot be opened.
    private func build(_ node: Layout.Node) -> NSView? {
        switch node {
        case let .pane(saved):
            guard let pane = try? makePane(in: saved.directory) else { return nil }
            pane.autoresizingMask = [.width, .height]
            resume(saved, in: pane)
            return pane
        case let .split(vertical, _, children):
            let split = PaneSplitView()
            split.isVertical = vertical
            split.dividerStyle = .thin
            split.autoresizingMask = [.width, .height]
            split.delegate = self
            for child in children {
                guard let view = build(child) else { continue }
                split.addArrangedSubview(view)
            }
            guard !split.arrangedSubviews.isEmpty else { return nil }
            return split.arrangedSubviews.count == 1 ? split.arrangedSubviews[0] : split
        }
    }

    /// Puts the dividers back where they were, once the views have a size.
    private func place(_ node: Layout.Node, in view: NSView) {
        guard case let .split(_, fractions, children) = node,
              let split = view as? NSSplitView,
              split.arrangedSubviews.count == children.count
        else { return }

        let total = split.isVertical ? split.bounds.width : split.bounds.height
        var offset: CGFloat = 0
        for index in 0 ..< (children.count - 1) {
            offset += total * fractions[index]
            split.setPosition(offset, ofDividerAt: index)
        }
        for (child, view) in zip(children, split.arrangedSubviews) {
            view.layoutSubtreeIfNeeded()
            place(child, in: view)
        }
    }

    /// Puts a pane back in the Claude Code session it was in.
    private func resume(_ saved: Layout.Pane, in pane: TerminalView?) {
        guard let pane, let id = saved.session else { return }
        pane.agentSession = id
        let command = Harness.claudeCode.resumeLine(id: id)
        // The shell has to be up to read what it is handed; the same hop a new
        // tab opening on a command already makes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pane.session.send(text: command)
        }
    }

    /// Splits the focused pane, side by side or stacked.
    @discardableResult
    func splitFocusedPane(vertical: Bool, in directory: String? = nil) -> TerminalView? {
        restorePanes()
        guard let pane = focusedPane else { return nil }
        let newPane: TerminalView
        do {
            // A split starts where the pane it came from is: the point of a
            // second terminal beside the first is to work in the same place.
            newPane = try makePane(in: directory ?? pane.session.currentDirectory?.path)
        } catch {
            NSSound.beep()
            return nil
        }
        guard insert(newPane, beside: pane, vertical: vertical) else { return nil }
        return newPane
    }

    /// Puts `newPane` next to `pane`, splitting whatever holds it.
    ///
    /// `pane` is any view of the split tree — a pane, or a whole split when a
    /// pane is being moved to an edge of the window.
    @discardableResult
    private func insert(
        _ newPane: TerminalView,
        beside pane: NSView,
        vertical: Bool,
        before: Bool = false
    ) -> Bool {
        guard let window else { return false }

        // Where the pane sits has to be recorded before it is detached:
        // removing it from the container clears the relationship, so asking
        // afterwards gives the wrong answer.
        let wasRoot = pane.superview === paneContainer
        let parentSplit = pane.superview as? NSSplitView
        let indexInParent = parentSplit?.arrangedSubviews.firstIndex(of: pane)
        guard wasRoot || (parentSplit != nil && indexInParent != nil) else { return false }

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
        if before {
            split.addArrangedSubview(newPane)
            split.addArrangedSubview(pane)
        } else {
            split.addArrangedSubview(pane)
            split.addArrangedSubview(newPane)
        }

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
        // A pane that was detached — moved here from another split, or to an
        // edge of this window — is off the list until it is put back on it.
        if !panes.contains(where: { $0 === newPane }) { panes.append(newPane) }
        window.makeFirstResponder(newPane)
        refreshFocusIndicators()
        syncMaximizeButtons()
        return true
    }

    /// Takes in a pane dropped from another window, or another split of this
    /// one, and puts it beside the pane it was dropped on.
    func accept(_ dropped: TerminalView, beside target: TerminalView, on edge: PaneEdge = .trailing) {
        guard dropped !== target else { return }
        let delegate = NSApp.delegate as? AppDelegate
        let source = delegate?.controller(owning: dropped) ?? self
        source.restorePanes()
        restorePanes()
        source.hand(over: dropped)
        if source !== self { adopt(dropped) }
        insert(dropped, beside: target, vertical: edge.isVertical, before: edge.isBefore)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(dropped)
        source.syncMaximizeButtons()
    }

    /// Lets a pane go without closing it: the window that receives it wires it
    /// up again. A window left with nothing closes, as it does on the last ×.
    private func hand(over pane: TerminalView) {
        guard remove(pane) else {
            window?.close()
            return
        }
        window?.makeFirstResponder(panes.first { $0.window != nil })
        syncMaximizeButtons()
    }

    /// Gives one pane the whole window, or gives the others their space back.
    ///
    /// The siblings are hidden rather than squeezed, for the same reason the
    /// preview panel hides them: a pane resized to a sliver reflows every line
    /// it holds, twice, for a view nobody is reading.
    func toggleMaximized(_ pane: TerminalView) {
        maximizedPane == nil ? maximize(pane) : restorePanes()
    }

    private func maximize(_ pane: TerminalView) {
        guard maximizedPane == nil, panes.count > 1 else { return }
        var child: NSView = pane
        while let split = child.superview as? NSSplitView {
            maximizeProportions.append((split, fractions(of: split)))
            for sibling in split.arrangedSubviews where sibling !== child && !sibling.isHidden {
                sibling.isHidden = true
                hiddenForMaximize.append(sibling)
            }
            split.adjustSubviews()
            child = split
        }
        maximizedPane = pane
        pane.isMaximized = true
        // Escape reaches this before anything in the pane sees it, which is
        // what makes the way back the same key everywhere in this app.
        paneEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.restorePanes()
            return nil
        }
        window?.makeFirstResponder(pane)
    }

    func restorePanes() {
        guard let pane = maximizedPane else { return }
        if let monitor = paneEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            paneEscapeMonitor = nil
        }
        hiddenForMaximize.forEach { $0.isHidden = false }
        hiddenForMaximize = []
        maximizedPane = nil
        pane.isMaximized = false

        // Outermost first: a divider set in a split that is itself about to be
        // resized ends up somewhere else.
        for (split, fractions) in maximizeProportions.reversed() {
            split.adjustSubviews()
            split.layoutSubtreeIfNeeded()
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            var offset: CGFloat = 0
            for (index, fraction) in fractions.dropLast().enumerated() {
                offset += fraction * total
                split.setPosition(offset, ofDividerAt: index)
                offset += split.dividerThickness
            }
        }
        maximizeProportions = []
        panes.forEach { $0.becameVisible() }
        window?.makeFirstResponder(pane)
    }

    /// How a split's panes divide it, as fractions of its length.
    private func fractions(of split: NSSplitView) -> [CGFloat] {
        let sizes = split.arrangedSubviews.map { split.isVertical ? $0.frame.width : $0.frame.height }
        let total = max(sizes.reduce(0, +), 1)
        return sizes.map { $0 / total }
    }

    /// Only a window with something to hide offers the button.
    private func syncMaximizeButtons() {
        panes.forEach { $0.canRearrange = panes.count > 1 }
    }

    /// Closes a pane, taking its shell with it.
    func close(_ pane: TerminalView) {
        // A window rearranged while one pane holds it would leave hidden views
        // nobody is tracking any more.
        restorePanes()
        pane.prepareForRemoval()
        guard remove(pane) else {
            // Last pane in the window: the window goes with it.
            window?.close()
            return
        }
        window?.makeFirstResponder(panes.first { $0.window != nil })
        syncMaximizeButtons()
    }

    /// Moves the focused pane to one edge of the window.
    ///
    /// The same rearranging as dragging a pane onto another, for the times the
    /// pointer is not where the hands are: the pane leaves its split, whatever
    /// it leaves behind closes up, and it comes back against that wall.
    func moveFocusedPane(to edge: PaneEdge) {
        restorePanes()
        guard panes.count > 1, let pane = focusedPane else {
            NSSound.beep()
            return
        }
        remove(pane)
        guard let rest = paneContainer.subviews.first else { return }
        insert(pane, beside: rest, vertical: edge.isVertical, before: edge.isBefore)
        syncMaximizeButtons()
    }

    /// Moves a pane into a tab of its own, shell and scrollback intact.
    func moveToNewTab(_ pane: TerminalView) {
        // A pane that is the whole tab already is what this would make.
        guard panes.count > 1 else { return }
        restorePanes()
        remove(pane)
        (NSApp.delegate as? AppDelegate)?.openTab(adopting: pane, from: self)
        window?.makeFirstResponder(panes.first { $0.window != nil })
        syncMaximizeButtons()
    }

    /// Detaches a pane from the split tree, collapsing whatever it leaves
    /// behind, and leaves it alive. False when it was the window's last one.
    @discardableResult
    private func remove(_ pane: TerminalView) -> Bool {
        panes.removeAll { $0 === pane }
        // Its browser goes with it: a page nobody can reach is a WebKit
        // process for nothing.
        panel?.dropBrowser(for: pane.paneID)
        refreshFocusIndicators()

        guard let split = pane.superview as? NSSplitView else {
            pane.removeFromSuperview()
            return false
        }

        // Same ordering care as splitting: read the position first, detach after.
        let splitWasRoot = split.superview === paneContainer
        let parentSplit = split.superview as? NSSplitView
        let indexInParent = parentSplit?.arrangedSubviews.firstIndex(of: split)
        let frame = split.frame

        pane.removeFromSuperview()
        guard let survivor = split.arrangedSubviews.first else { return true }

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
        return true
    }

    // MARK: - Preview panel

    /// Shows a file in the side panel, opening the panel if it is closed.
    func preview(_ target: PreviewTarget) {
        openPanel().show(target)
    }

    /// The browser in the side panel, opening the panel if it is closed.
    ///
    /// One per pane: the sidebar is per session, so an agent in one pane and
    /// an agent in the next each drive a browser of their own and never see
    /// the other's page. With no pane named, the focused one's.
    func browser(for pane: TerminalView? = nil) -> BrowserView {
        let key = (pane ?? focusedPane)?.paneID ?? ""
        return openPanel().browser(for: key.isEmpty ? "window" : key)
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
        tint(panelButton, on: panel != nil)
    }

    @discardableResult
    private func openPanel() -> PreviewPanel {
        if let panel { return panel }

        let panel = PreviewPanel(frame: .zero)
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onToggleMaximize = { [weak self] in self?.togglePanelMaximized() }
        panel.onDirectorySelected = { [weak self] url in self?.followDirectory(url) }
        panelBrowsedAway = false
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

        split.onDividerDoubleClick = { [weak self] in self?.togglePanelMaximized() }

        self.panel = panel
        self.panelSplit = split
        syncPanelButton()
        return panel
    }

    /// Double-clicking the panel's divider gives it the whole window, and
    /// Escape gives the terminal its half back.
    ///
    /// The panes are hidden rather than squeezed: the divider cannot go past
    /// the width the terminal is guaranteed, and a pane resized to nothing
    /// would reflow every line it holds twice for a view nobody is reading.
    private func togglePanelMaximized() {
        isPanelMaximized ? restorePanel() : maximizePanel()
    }

    private var isPanelMaximized: Bool { panelRestoreWidth != nil }

    private func maximizePanel() {
        guard panelSplit != nil, !isPanelMaximized else { return }
        panelRestoreWidth = paneContainer.frame.width
        paneContainer.isHidden = true
        panelSplit?.adjustSubviews()
        panel?.isMaximized = true
        // Escape reaches this before the web view, which would otherwise stop
        // a page load with it and never tell us.
        panelEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.restorePanel()
            return nil
        }
    }

    private func restorePanel() {
        guard let width = panelRestoreWidth else { return }
        if let monitor = panelEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            panelEscapeMonitor = nil
        }
        panelRestoreWidth = nil
        paneContainer.isHidden = false
        panel?.isMaximized = false
        panelSplit?.adjustSubviews()
        panelSplit?.setPosition(width, ofDividerAt: 0)
        panes.forEach { $0.becameVisible() }
        window?.makeFirstResponder(focusedPane)
    }

    private func closePanel() {
        guard let panel, let split = panelSplit else { return }
        restorePanel()
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

    /// The red button puts Vitra away rather than closing it.
    ///
    /// A window here is not a document: it holds running shells, and a Claude
    /// Code session that took ten minutes to get into. Closing one would end
    /// them, so the button does what most apps of this shape do — hides the
    /// app, leaving everything running. Clicking the Dock icon brings it back.
    /// Cmd-Q quits, `Close Pane` closes one terminal, and the × in a pane's
    /// corner does the same.
    /// A window that is not on screen stops drawing.
    ///
    /// Switching tabs, minimising, hiding the app: AppKit says so here, and
    /// there is no reason to spend a display link or 50 MB of GPU surfaces on a
    /// window nobody is looking at. Whatever is running keeps running.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window?.occlusionState.contains(.visible) ?? true
        panes.forEach { $0.setDrawingActive(visible) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A tab among others closes: that button means "close this tab", and
        // the rest of the workspace stays on screen. The last window is the
        // whole app, and hiding it is what keeps the shells running.
        if let group = sender.tabGroup, group.windows.count > 1 { return true }
        NSApp.hide(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.prepareForRemoval() }
        panes.forEach { $0.session.terminate() }
        panes.removeAll()
        // The app keeps the controllers; a closed one has to be let go, or it
        // lives on as a window with no panes — invisible, and saved into the
        // layout as a tab that opens empty on the next launch.
        if let window = notification.object as? NSWindow {
            (NSApp.delegate as? AppDelegate)?.windowWillClose(window)
        }
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

    /// No divider when there is nothing on both sides of it: hiding a subview
    /// leaves AppKit drawing the line it was dragging.
    override func drawDivider(in rect: NSRect) {
        guard arrangedSubviews.filter({ !$0.isHidden }).count > 1 else { return }
        super.drawDivider(in: rect)
    }

    /// Called when a divider is double-clicked, which AppKit otherwise spends
    /// on collapsing a subview this split view never collapses.
    var onDividerDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let onDivider = (0..<max(arrangedSubviews.count - 1, 0)).contains { index in
            let drawn = dividerRect(at: index)
            return drawn.insetBy(
                dx: isVertical ? -PanelStyle.dividerGrab : 0,
                dy: isVertical ? 0 : -PanelStyle.dividerGrab
            ).contains(point)
        }
        guard event.clickCount == 2, onDivider, let handler = onDividerDoubleClick else {
            super.mouseDown(with: event)
            return
        }
        handler()
    }

    /// Where a divider is drawn, which AppKit knows and does not expose.
    private func dividerRect(at index: Int) -> NSRect {
        let before = arrangedSubviews[index].frame
        return isVertical
            ? NSRect(x: before.maxX, y: bounds.minY, width: dividerThickness, height: bounds.height)
            : NSRect(x: bounds.minX, y: before.maxY, width: bounds.width, height: dividerThickness)
    }

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
        // A hidden pane — a sibling of the maximised one — takes no room and
        // is laid out nowhere: scaling it along with the rest is what left a
        // black band where it used to be, because its frame still counted.
        let vertical = splitView.isVertical
        for view in splitView.arrangedSubviews where view.isHidden { view.frame = .zero }
        let views = splitView.arrangedSubviews.filter { !$0.isHidden }
        guard views.count > 1 else {
            // One pane left showing: it is the whole split, however the old
            // frames were divided.
            views.first?.frame = splitView.bounds
            return
        }

        let dividers = splitView.dividerThickness * CGFloat(views.count - 1)
        // Proportions come from what the visible panes have now, not from the
        // old size of the whole split, which may have included a pane that
        // has since been hidden.
        let oldAvailable = views.reduce(CGFloat(0)) { $0 + (vertical ? $1.frame.width : $1.frame.height) }
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

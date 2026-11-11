import AppKit
import Metal
import VitraBridge
import VitraCore
import VitraGhostty
import VitraOrchestrator
import VitraPanel

/// What a project's terminal is built from, shared by every project.
struct TerminalKit {
    let device: MTLDevice
    let config: Config
}

/// The maestro's header row. Reports its width so the project can decide which
/// of the plates fit, before the layout pass that would squeeze them.
private final class MaestroHeader: NSStackView {
    var onResize: ((CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize.width)
    }
}

/// One project: the maestro's terminal on the left and, on the right, tabs
/// for its workers, their ranking, a browser, the project's files and what
/// was last done in its repository.
final class ProjectView: NSView {
    let project: CockpitProject
    let workers = WorkersPanel()

    /// What this project is called in its shell's environment (`VITRA_PANE`).
    /// The maestro's `vitra mcp` helper inherits it, and so does every worker
    /// the maestro spawns, which is how a tool call from any of them finds its
    /// way back to this project and not to whichever tab is in front.
    let paneID = UUID().uuidString

    /// How much of the window the right side takes while it shows a page or
    /// a file, which need room to be read.
    private static let wideShare: CGFloat = 0.5

    /// Fetches how each worker has done so far, for the Ranking tab.
    var loadRanking: ((@escaping @MainActor @Sendable ([ModelScore]) -> Void) -> Void)?

    private let side = NSView()
    private let tabs = SideTabs()
    private let tabSlot = NSView()
    private let ranking = RankingView()
    private lazy var git: GitPanel = {
        let panel = GitPanel(path: project.path)
        panel.onOpenURL = { [weak self] url in self?.usersBrowser().load(url) { _ in } }
        return panel
    }()
    private var browserTabs = BrowserTabs()
    private var runTitles: [String: String] = [:]
    private let browserStrip = BrowserTabStrip()
    private let browserPanelSlot = NSView()
    /// The Navegador tab: the browser's own tabs, and the page under them.
    private lazy var browserArea: NSView = {
        let area = NSView()
        let rule = NSView.rule(CockpitStyle.softLine)
        for view in [browserStrip, rule, browserPanelSlot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            area.addSubview(view)
        }
        browserPanelSlot.addFilling(browserPanel)
        browserStrip.onSelect = { [weak self] id in self?.showBrowserTab(id) }
        browserStrip.onNew = { [weak self] in
            guard let self else { return }
            self.showBrowserTab(self.browserTabs.openUsers(now: Date()))
            self.browserPanel.currentBrowser?.focusAddress()
        }
        NSLayoutConstraint.activate([
            browserStrip.topAnchor.constraint(equalTo: area.topAnchor),
            browserStrip.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            browserStrip.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            browserStrip.heightAnchor.constraint(equalToConstant: BrowserTabStrip.height),
            rule.topAnchor.constraint(equalTo: browserStrip.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            browserPanelSlot.topAnchor.constraint(equalTo: rule.bottomAnchor),
            browserPanelSlot.leadingAnchor.constraint(equalTo: area.leadingAnchor),
            browserPanelSlot.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            browserPanelSlot.bottomAnchor.constraint(equalTo: area.bottomAnchor),
        ])
        return area
    }()
    /// The shell the user and the agents share, in the Terminal tab. Started
    /// the first time anyone wants it.
    private var sharedTerminalView: TerminalView?
    private let sharedTerminalSlot = NSView()
    private var housekeeping: Timer?
    private var activityMonitor: Any?
    // Two panels, not one: a page left open in the Navegador tab must still be
    // there after a look at a file in Arquivos.
    private lazy var browserPanel = makePanel(for: .browser)
    private lazy var filesPanel = makePanel(for: .files)
    private lazy var filesArea = FilesArea(panel: filesPanel, root: URL(fileURLWithPath: project.path))
    private var sideNarrow: NSLayoutConstraint?
    private var sideWide: NSLayoutConstraint?

    /// What the terminal is sized to until the window lays it out for real.
    private static let provisionalSize = NSSize(width: 800, height: 600)

    private static let exitWindow: TimeInterval = 5
    private static let exitsBeforeGivingUp = 3

    private var recentExits: [Date] = []
    private var isShutDown = false
    private let kit: TerminalKit
    private let terminalSlot = NSView()
    private let place: NSTextField = {
        let label = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
        // A long path loses its beginning, not the folder and branch at its end.
        label.lineBreakMode = .byTruncatingHead
        label.alignment = .right
        return label
    }()
    private(set) var terminal: TerminalView?
    private let usage = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private lazy var usagePill = NSView.pill([usage])
    private let attention = NSTextField.label(font: CockpitStyle.label, color: CockpitStyle.accent)
    private lazy var attentionPill = NSView.pill([attention])
    private let model = NSTextField.label("claude", font: CockpitStyle.label, color: CockpitStyle.accent)
    private let effort = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let session = NSTextField.label(font: CockpitStyle.label, color: CockpitStyle.text)
    private lazy var sessionPill = NSView.pill([session])
    private let branch = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.code)
    private lazy var branchPill: NSView = {
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch") ?? NSImage())
        icon.contentTintColor = CockpitStyle.muted
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: CockpitStyle.iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: CockpitStyle.iconSize).isActive = true
        return NSView.pill([icon, branch])
    }()
    private let titleLabel = NSTextField.label("Maestro", font: CockpitStyle.title, color: CockpitStyle.text)
    private lazy var modelPill = NSView.pill([model, effort])
    /// The maestro's session name, when it has told one; what the header can
    /// hide is decided by `fitHeader`.
    private var sessionName: String?
    /// Whether there is a usage figure; the plate is shown only if it also fits.
    private var usageIsKnown = false
    private var headerWidth: CGFloat = 0
    /// Narrower than this the session name is cut to an ellipsis; narrower
    /// than what it takes to keep this and the path's minimum, it is hidden.
    private static let sessionMinWidth: CGFloat = 96
    private static let placeMinWidth: CGFloat = 56

    /// `startsTerminal: false` builds the view without a shell, a timer or an
    /// event monitor; the UI snapshot tool uses it to lay the project out
    /// offscreen. The app always starts the terminal.
    init(project: CockpitProject, kit: TerminalKit, startsTerminal: Bool = true) {
        self.project = project
        self.kit = kit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.ground.cgColor
        build()
        guard startsTerminal else { return }
        startHousekeeping()
        startTerminal(launchingMaestro: true)
    }

    /// Where the maestro's terminal goes, for the snapshot tool to fill.
    var terminalArea: NSView { terminalSlot }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows how much of the week's subscription is used, or nothing when
    /// that is not known.
    func show(usage label: UsageLabel?) {
        usage.stringValue = label?.text ?? ""
        usageIsKnown = label != nil
        usage.textColor = switch label?.level {
        case .hot: CockpitStyle.dangerText
        case .warm: CockpitStyle.accent
        case .calm, nil: CockpitStyle.muted
        }
        usage.toolTip = "Uso semanal da assinatura Claude, como o maestro informou por último"
        fitHeader()
    }

    /// Shows that the maestro waits on the user, and for how long, or nothing.
    func show(attention text: String?) {
        guard attention.stringValue != (text ?? "") else { return }
        attention.stringValue = text ?? ""
        attentionPill.isHidden = text == nil
        fitHeader()
    }

    /// Shows which model the maestro is on and at what effort, as it last
    /// told its status line; until then, only that it is claude.
    func show(model current: MaestroModel?) {
        model.stringValue = current?.name ?? "claude"
        effort.stringValue = current?.effort ?? ""
        effort.isHidden = current?.effort == nil
        session.stringValue = current?.session ?? ""
        session.toolTip = current?.session
        sessionName = current?.session
        fitHeader()
    }

    /// Shows the session plate only when the header has room for it at its
    /// minimum width beside everything that never gives way. Decided from the
    /// header's width, not from how the layout came out, so it cannot flap.
    ///
    /// What gives way, first to last: the session name, then the usage figure
    /// (the tab bar's chip says it too once it is worth saying), and only then
    /// the path. Model, effort, "waiting for you" and branch never clip.
    private func fitHeader() {
        let core = [titleLabel, modelPill, attentionPill, branchPill].filter { !$0.isHidden }
        // Before the first layout there is no width to decide from.
        let hasRoom = { (plates: [NSView], withSession: Bool) -> Bool in
            self.headerWidth == 0 || self.headerWidth >= self.headerNeeds(plates, withSession: withSession)
        }
        let showsUsage = usageIsKnown && hasRoom(core + [usagePill], false)
        usagePill.isHidden = !showsUsage
        let plates = showsUsage ? core + [usagePill] : core
        sessionPill.isHidden = sessionName == nil || !hasRoom(plates, true)
    }

    /// The width the header needs for `plates`, the spacer, the path at its
    /// minimum and, when asked, the session plate at its minimum.
    private func headerNeeds(_ plates: [NSView], withSession: Bool) -> CGFloat {
        let visible = plates.count + 2 + (withSession ? 1 : 0)
        let widths = plates.map(\.fittingSize.width).reduce(0, +)
        let gaps = CGFloat(visible - 1) * CockpitStyle.Space.md + (CockpitStyle.Space.lg - CockpitStyle.Space.md)
        return 2 * CockpitStyle.inset + widths + gaps + Self.placeMinWidth + (withSession ? Self.sessionMinWidth : 0)
    }

    /// Hands the keyboard to the maestro.
    func focusTerminal() {
        guard let terminal else { return }
        window?.makeFirstResponder(terminal)
    }

    /// Stops or resumes drawing, for a project whose tab is not the one shown.
    /// The maestro keeps running either way.
    func setShown(_ shown: Bool) {
        terminal?.setDrawingActive(shown)
        if shown { refreshPlace() }
        // The Git tab re-reads the repository on a timer; not for a project
        // nobody is looking at.
        if tabs.selected == .git { git.setActive(shown) }
        sharedTerminalView?.setDrawingActive(shown && tabs.selected == .terminal)
    }

    /// Whether something is running in the project's shell beyond the shell
    /// itself — the maestro, most likely.
    var isBusy: Bool { terminal?.session.isRunningProgram ?? false }

    /// Ends the project's shell and everything in it.
    func shutDown() {
        git.setActive(false)
        sharedTerminalView?.session.onExit = nil
        sharedTerminalView?.session.terminate()
        sharedTerminalView?.prepareForRemoval()
        housekeeping?.invalidate()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        browserTabs.tabs.map(\.id).forEach(browserPanel.dropBrowser(for:))
        browserPanel.clearContent()
        filesPanel.clearContent()
        isShutDown = true
        terminal?.session.onExit = nil
        terminal?.session.terminate()
        terminal?.prepareForRemoval()
    }

    // MARK: - The tabs of the right side

    /// Shows the workers and, on the tab, how many are running.
    func show(_ runs: [Run], now: Date) {
        workers.show(runs, now: now)
        // A worker that is done has no more use for its tab, and each tab
        // open is memory held.
        runTitles = Dictionary(runs.map { ($0.id, $0.spec.label ?? $0.spec.worker) }) { first, _ in first }
        let isRunning = Dictionary(runs.map { ($0.id, $0.state == .running) }) { first, _ in first }
        browserTabs.finished(isRunning: isRunning).forEach(closeBrowserTab)
        refreshBrowserStrip()
        let running = workers.runningCount
        tabs.setTitle(running == 0 ? SideTab.workers.title : "\(SideTab.workers.title) · \(running)", for: .workers)
    }

    /// Brings a tab of the right side to the front.
    func select(_ tab: SideTab) {
        let previous = tabs.selected
        tabs.select(tab)
        if previous == .git, tab != .git { git.setActive(false) }

        let content: NSView
        switch tab {
        case .workers:
            content = workers
        case .ranking:
            content = ranking
            // ponytail: read when the tab is opened, not live; reopen the tab
            // to refresh. Follow the run feed if that ever matters.
            loadRanking? { [weak self] scores in self?.ranking.show(WorkerBoard.ranking(scores)) }
        case .browser:
            // Opened by hand with nothing in it: a tab of the user's own.
            if browserTabs.current == nil { _ = browserTabs.openUsers(now: Date()) }
            if let id = browserTabs.current { _ = browserPanel.browser(for: id) }
            refreshBrowserStrip()
            content = browserArea
        case .files:
            if filesPanel.target == nil, !filesPanel.isListingFiles {
                filesPanel.showFiles(in: URL(fileURLWithPath: project.path))
            }
            content = filesArea
        case .git:
            git.setActive(true)
            content = git
        case .terminal:
            guard (try? sharedTerminal(showing: false)) != nil else { return }
            content = sharedTerminalSlot
        }
        // A terminal nobody can see is not drawn.
        sharedTerminalView?.setDrawingActive(tab == .terminal)

        // A maximized panel sits over the whole project; leave it there.
        let panel = tab == .browser ? browserPanel : (tab == .files ? filesPanel : nil)
        if panel?.isMaximized != true, content.superview !== tabSlot {
            tabSlot.subviews.forEach { $0.removeFromSuperview() }
            tabSlot.addFilling(content)
        }
        // Off before on: both held at once cannot be satisfied.
        (tab.isWide ? sideNarrow : sideWide)?.isActive = false
        (tab.isWide ? sideWide : sideNarrow)?.isActive = true
    }

    /// Shows a file in the Arquivos tab.
    func preview(_ target: PreviewTarget) {
        // So the back arrow leads to the project's files, not to nothing.
        if filesPanel.target == nil, !filesPanel.isListingFiles {
            filesPanel.rememberDirectory(URL(fileURLWithPath: project.path))
        }
        filesPanel.show(target)
        filesArea.showPanel()
        select(.files)
    }

    // MARK: - The shared terminal

    /// The shell the user and the agents share, started if it was not.
    /// `showing` brings its tab forward and hands it the keyboard.
    func sharedTerminal(showing: Bool) throws -> TerminalSession {
        if sharedTerminalView == nil {
            let view: TerminalView
            do { view = try makeTerminal() } catch {
                throw ToolError("could not start the shared terminal: \(error.localizedDescription)")
            }
            // `exit` there closes the tab; the next visit starts a fresh shell.
            view.session.onExit = { [weak self] _ in
                DispatchQueue.main.async { self?.sharedTerminalExited() }
            }
            view.frame = NSRect(origin: .zero, size: Self.provisionalSize)
            view.layoutSubtreeIfNeeded()
            sharedTerminalSlot.addFilling(view)
            sharedTerminalView = view
            view.session.start()
            view.setDrawingActive(tabs.selected == .terminal)
        }
        guard let view = sharedTerminalView else { throw ToolError("the shared terminal is not open") }
        if showing {
            select(.terminal)
            window?.makeFirstResponder(view)
        }
        return view.session
    }

    private func sharedTerminalExited() {
        sharedTerminalView?.prepareForRemoval()
        sharedTerminalView?.removeFromSuperview()
        sharedTerminalView = nil
        if tabs.selected == .terminal, !isShutDown {
            select(.workers)
            focusTerminal()
        }
    }

    // MARK: - The browser's tabs

    /// The calling agent's own tab, opened if it had none, and whether it
    /// was opened just now. `agent` is a worker's run, or nil for the maestro.
    func browser(agent: String?) -> (BrowserView, isNew: Bool) {
        let id = BrowserTabs.id(forAgent: agent)
        let isNew = browserTabs.use(id, now: Date())
        if !isNew, let kept = browserPanel.keptBrowser(for: id) {
            return (kept, false)
        }
        // New: it comes to the front, once, so what the agent is doing can be
        // seen. After that it works where it is and the view is left alone.
        browserTabs.show(id)
        select(.browser)
        return (browserPanel.browser(for: id), isNew)
    }

    /// A tab to look at, whoever it belongs to.
    func browser(tab id: String) throws -> BrowserView {
        guard browserTabs.contains(id), let browser = browserPanel.keptBrowser(for: id) else {
            let open = browserTabs.tabs.map(\.id).joined(separator: ", ")
            throw ToolError("there is no tab '\(id)'. Open tabs: \(open.isEmpty ? "none" : open)")
        }
        return browser
    }

    /// The tabs as an agent reads them: id, owner, page, and which is its own.
    func browserTabList(agent: String?) -> [String] {
        let own = BrowserTabs.id(forAgent: agent)
        return browserTabs.tabs.map { tab in
            let browser = browserPanel.keptBrowser(for: tab.id)
            let page = [browser?.currentTitle ?? "", browser?.currentURL?.absoluteString ?? "(blank)"].filter { !$0.isEmpty }
            let parts = [tab.id, BrowserTabs.label(tab.id, runTitle: runTitles[tab.id])] + page
            return parts.joined(separator: " · ") + (tab.id == own ? " (yours)" : "")
        }
    }

    /// A tab of the user's own, in front: the one they are on if it is
    /// theirs, otherwise a new one. An agent's tab is not theirs to steer.
    private func usersBrowser() -> BrowserView {
        let id = browserTabs.current.flatMap { BrowserTabs.isUsers($0) ? $0 : nil } ?? browserTabs.openUsers(now: Date())
        browserTabs.touch(id, now: Date())
        select(.browser)
        return browserPanel.browser(for: id)
    }

    private func showBrowserTab(_ id: String) {
        browserTabs.show(id)
        browserTabs.touch(id, now: Date())
        if tabs.selected == .browser, let current = browserTabs.current {
            _ = browserPanel.browser(for: current)
        }
        refreshBrowserStrip()
    }

    private func closeBrowserTab(_ id: String) {
        guard browserTabs.contains(id) else { return }
        // Let go of, not hidden: a page kept alive behind a closed tab is a
        // WebKit process holding memory for something nobody can see.
        browserPanel.dropBrowser(for: id)
        browserTabs.close(id)
        if let current = browserTabs.current {
            if tabs.selected == .browser { _ = browserPanel.browser(for: current) }
        } else {
            if browserPanel.isMaximized { toggleMaximized(browserPanel) }
            browserPanel.clearContent()
            if tabs.selected == .browser {
                select(.workers)
                focusTerminal()
            }
        }
        refreshBrowserStrip()
    }

    private func refreshBrowserStrip() {
        let items = browserTabs.tabs.map { tab in
            let label = BrowserTabs.label(tab.id, runTitle: runTitles[tab.id])
            let page = browserPanel.keptBrowser(for: tab.id)?.currentURL?.absoluteString
            return BrowserTabStrip.Item(id: tab.id, label: label, tip: [label, page].compactMap { $0 }.joined(separator: "\n"))
        }
        browserStrip.show(items, current: browserTabs.current)
    }

    /// Closes the tabs left untouched too long, and notes the user's own use
    /// of the page in front, which no tool call reports.
    private func startHousekeeping() {
        housekeeping = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.browserTabs.idle(now: Date()).forEach(self.closeBrowserTab)
            }
        }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.tabs.selected == .browser,
                      let current = self.browserTabs.current else { return }
                let inPage = event.type == .keyDown
                    ? (self.window?.firstResponder as? NSView)?.isDescendant(of: self.browserPanel) == true
                    : self.browserPanel.bounds.contains(self.browserPanel.convert(event.locationInWindow, from: nil))
                if inPage { self.browserTabs.touch(current, now: Date()) }
            }
            return event
        }
    }

    /// Closes the page or file on the right side, if that is what is showing.
    /// False when there was nothing of the kind to close.
    ///
    /// ⌘W closes the innermost thing first, as it does in a browser: with a
    /// page open, the page; only then the project and its maestro.
    func closeSidePanel() -> Bool {
        guard tabs.selected.isWide else { return false }
        if tabs.selected == .terminal {
            // The tab is put away; the shell and whatever runs in it stay.
            select(.workers)
            focusTerminal()
            return true
        }
        (tabs.selected == .browser ? browserPanel : filesPanel).onClose?()
        return true
    }

    private func makePanel(for tab: SideTab) -> PreviewPanel {
        let panel = PreviewPanel()
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            // The browser's close button closes the tab in front, not all of them.
            if tab == .browser {
                if let current = self.browserTabs.current { self.closeBrowserTab(current) }
                return
            }
            if panel.isMaximized { self.toggleMaximized(panel) }
            panel.clearContent()
            self.filesArea.reset()
            self.select(.workers)
            self.focusTerminal()
        }
        panel.onToggleMaximize = { [weak self, weak panel] in
            if let panel { self?.toggleMaximized(panel) }
        }
        return panel
    }

    /// Gives a panel the whole project, or gives the rest its space back.
    private func toggleMaximized(_ panel: PreviewPanel) {
        panel.removeFromSuperview()
        panel.isMaximized.toggle()
        let home = panel === browserPanel ? browserPanelSlot : filesArea.panelSlot
        (panel.isMaximized ? self : home).addFilling(panel)
    }

    // MARK: - The maestro's terminal

    /// Starts a shell in the project and, the first time, the maestro in it.
    ///
    /// The maestro runs inside a login shell rather than as the terminal's own
    /// program: it finds `claude` on the user's real PATH, and when it exits
    /// the user is left at a prompt in the project instead of a dead pane.
    private func startTerminal(launchingMaestro: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showFailure("A pasta deste projeto não está mais aqui: \(project.path)")
            return
        }
        do {
            let view = try makeTerminal()
            let session = view.session
            view.paneID = paneID

            // The shell ending — `exit`, or the maestro's shell dying — leaves
            // a fresh prompt, never an empty pane. The maestro is not started
            // again by itself: a shell that keeps dying would loop for ever.
            session.onExit = { [weak self] _ in
                DispatchQueue.main.async { self?.shellExited() }
            }

            terminal?.prepareForRemoval()
            terminal?.removeFromSuperview()
            // The terminal lays its own parts out with autoresizing masks. It
            // is given a real size before it joins the window, because a mask
            // read against a zero-sized view becomes a constraint with an
            // absurd constant.
            view.frame = NSRect(origin: .zero, size: terminalSlot.bounds.size == .zero ? Self.provisionalSize : terminalSlot.bounds.size)
            view.layoutSubtreeIfNeeded()
            terminalSlot.addFilling(view)
            terminal = view

            session.start()
            if launchingMaestro, let binary = Bundle.main.executablePath {
                // Failing to write the maestro's files leaves a working shell
                // in the project; the reason is printed where the user is looking.
                do {
                    let line = try Maestro.install(
                        binary: binary,
                        claude: Harness.claudeCode.launchLine,
                        // The project's own conversation: carried on when
                        // there is one, started under its id when not.
                        // What the maestro was last in comes first: the user
                        // may have moved to another conversation with /resume,
                        // and that one is where they left off.
                        conversation: Maestro.conversation(
                            Maestro.rememberedSession(for: project.path)
                                ?? project.session
                                ?? UUID().uuidString.lowercased(),
                            project: project.path
                        ),
                        in: Maestro.supportDirectory
                    )
                    session.send(text: line)
                } catch {
                    // Printed, not written as a comment: zsh does not take `#`
                    // as one at a prompt, and would try to run the message.
                    let message = "Vitra: não deu para preparar o maestro (\(error.localizedDescription))"
                    session.send(text: "printf '%s\\n' " + ShellQuote.quote(message) + "\n")
                }
            }
            if window != nil { focusTerminal() }
        } catch {
            showFailure("Não deu para abrir o terminal: \(error.localizedDescription)")
        }
    }

    /// A login shell in the project, in a terminal of its own. Both of the
    /// project's terminals are made here: the maestro's and the shared one.
    private func makeTerminal() throws -> TerminalView {
        let size = TerminalSize(columns: 80, rows: 24)
        let shell = kit.config.shell ?? ShellEnvironment.loginShell()
        let session = try TerminalSession(
            core: try GhosttyTerminalCore(size: size),
            executable: shell,
            arguments: ["-l"],
            environment: ShellEnvironment.childEnvironment(
                shell: shell,
                shellIntegration: kit.config.shellIntegration,
                blockSpacing: kit.config.blockSpacing,
                colorPrompt: kit.config.colorPrompt,
                colorDefaults: kit.config.colorDefaults,
                // The pane routes tool calls back here; the project is
                // what the session hook files its conversation under.
                extra: ["VITRA_PANE": paneID, "VITRA_PROJECT": project.path]
            ),
            size: size,
            workingDirectory: project.path
        )
        let view = try TerminalView(
            session: session,
            device: kit.device,
            fontName: kit.config.fontName,
            fontSize: CGFloat(kit.config.fontSize)
        )
        try? view.apply(kit.config)
        view.offersClose = false
        view.focusTint = CockpitStyle.accent
        return view
    }

    /// Gives the project a fresh shell, unless shells keep dying here.
    ///
    /// A shell that exits as it starts — a broken profile, say — would
    /// otherwise be replaced for ever, a new PTY and a new Metal view each
    /// time round.
    private func shellExited() {
        guard !isShutDown else { return }
        let now = Date()
        recentExits = recentExits.filter { now.timeIntervalSince($0) < Self.exitWindow } + [now]
        guard recentExits.count < Self.exitsBeforeGivingUp else {
            terminal?.prepareForRemoval()
            terminal?.removeFromSuperview()
            terminal = nil
            showFailure("O shell deste projeto fechou \(recentExits.count) vezes seguidas ao abrir. Confira o seu perfil de shell e reabra o projeto.")
            return
        }
        startTerminal(launchingMaestro: false)
    }

    private func showFailure(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = CockpitStyle.ui(13)
        label.textColor = CockpitStyle.dangerText
        terminalSlot.addFilling(label, inset: 24)
    }

    /// The project's folder and git branch, for the header.
    private func refreshPlace() {
        let home = NSHomeDirectory()
        let path = project.path.hasPrefix(home) ? "~" + project.path.dropFirst(home.count) : project.path
        // Read straight from .git/HEAD: one small file, and no git to spawn.
        let head = try? String(contentsOfFile: project.path + "/.git/HEAD", encoding: .utf8)
        let branch = head?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "refs/heads/")
            .dropFirst()
            .first
        place.stringValue = path
        self.branch.stringValue = branch ?? ""
        branchPill.isHidden = branch == nil
        fitHeader()
    }

    // MARK: - Layout

    private func build() {
        let title = titleLabel
        // Each fact on a plate of its own: which model and how hard it is
        // thinking, how much of the week is spent, and on the far side where
        // the project is and on which branch.
        effort.isHidden = true
        modelPill.toolTip = "Modelo e effort do maestro"
        usagePill.isHidden = true
        attentionPill.isHidden = true
        attentionPill.toolTip = "O maestro parou e espera por você"
        for view in [title, usage, attention, model, effort, branch, modelPill, usagePill, attentionPill, branchPill] as [NSView] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // What gives way, in this order: the path (head-truncated, lowest
        // priority), then the session name, which truncates down to a minimum
        // width and is hidden below it — never drawn as an empty plate. The
        // model, effort, usage and branch plates never clip.
        place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        place.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.placeMinWidth).isActive = true
        session.lineBreakMode = .byTruncatingTail
        session.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        session.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionPill.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        sessionPill.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.sessionMinWidth).isActive = true
        sessionPill.isHidden = true
        let header = MaestroHeader(views: [title, modelPill, attentionPill, usagePill, sessionPill, NSView(), place, branchPill])
        header.spacing = CockpitStyle.Space.md
        header.setCustomSpacing(CockpitStyle.Space.lg, after: title)
        header.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.inset)
        header.onResize = { [weak self] width in
            self?.headerWidth = width
            self?.fitHeader()
        }
        refreshPlace()

        let headerRule = NSView.rule(CockpitStyle.softLine)
        let divider = NSView.rule(CockpitStyle.line, vertical: true)
        for view in [header, headerRule, terminalSlot, divider, side] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let tabsRule = NSView.rule(CockpitStyle.softLine)
        for view in [tabs, tabsRule, tabSlot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(view)
        }
        tabs.onSelect = { [weak self] tab in
            guard let self else { return }
            self.select(tab)
            if tab == .terminal, let view = self.sharedTerminalView { self.window?.makeFirstResponder(view) }
        }
        tabSlot.addFilling(workers)

        // The right side has two shapes: narrow for the lists, and half the
        // window for a page or a file.
        let narrow = side.widthAnchor.constraint(equalToConstant: CockpitStyle.workersWidth)
        let wide = side.widthAnchor.constraint(equalTo: widthAnchor, multiplier: Self.wideShare)
        (sideNarrow, sideWide) = (narrow, wide)

        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: topAnchor),
            side.bottomAnchor.constraint(equalTo: bottomAnchor),
            side.trailingAnchor.constraint(equalTo: trailingAnchor),
            narrow,
            tabs.topAnchor.constraint(equalTo: side.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: CockpitStyle.headerHeight),
            tabsRule.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            tabsRule.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            tabsRule.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            tabSlot.topAnchor.constraint(equalTo: tabsRule.bottomAnchor),
            tabSlot.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            tabSlot.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            tabSlot.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: side.leadingAnchor),

            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            header.heightAnchor.constraint(equalToConstant: CockpitStyle.headerHeight),
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: divider.leadingAnchor),

            terminalSlot.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            terminalSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalSlot.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            terminalSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

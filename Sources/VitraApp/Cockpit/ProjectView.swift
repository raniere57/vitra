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
    /// The live stage and timeline of the workers: the Palco tab.
    private(set) lazy var palco: PalcoView = {
        let view = PalcoView(repository: project.path)
        view.onOpenWorker = { [weak self] id in
            self?.select(.workers)
            self?.workers.reveal(id)
        }
        return view
    }()

    /// What this project is called in its shell's environment (`VITRA_PANE`).
    /// The maestro's `vitra mcp` helper inherits it, and so does every worker
    /// the maestro spawns, which is how a tool call from any of them finds its
    /// way back to this project and not to whichever tab is in front.
    ///
    /// The project's path, not a fresh id: a maestro that outlived the app in
    /// the pty-host still carries the old value, and must still be routed
    /// here by the next app.
    var paneID: String { project.path }

    /// The project's two terminals as the pty-host holds them, when it does.
    private var maestroHost: HostedPTY?
    private var sharedHost: HostedPTY?

    private let side = NSView()
    private let tabs = SideTabs()
    private let tabsRule = NSView.rule(CockpitStyle.softLine)
    private let tabSlot = NSView()
    private let ranking = RankingView()
    /// Works out the Resumo tab off the main thread, for this project.
    var loadResumo: ((@escaping @MainActor @Sendable (Resumo) -> Void) -> Void)?
    private let resumo = ResumoView()
    /// What the runs looked like when the Resumo was last worked out: a clock
    /// that moves is no reason to read 2,000 runs again, a run that ends is.
    private var resumoSignature: Int?
    private var resumoReload: DispatchWorkItem?
    private static let resumoDelay: TimeInterval = 0.5
    private lazy var git: GitPanel = {
        let panel = GitPanel(path: project.path)
        panel.onOpenURL = { [weak self] url in self?.usersBrowser().load(url) { _ in } }
        return panel
    }()
    /// Where this project's browsers wait while not on screen; the window's.
    var browserParking: NSView? {
        didSet { browserPanel.parkingLot = browserParking }
    }

    private var browserTabs = BrowserTabs()
    /// Tabs brought back from before a restart, not loaded yet.
    private var pendingPages: [String: URL] = [:]
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
    /// The panel put away: no width at all.
    private var sideCollapsed: NSLayoutConstraint?
    private let divider = NSView.rule(CockpitStyle.line, vertical: true)
    /// ⌘\: the panel in the other of its two widths, until another tab is chosen.
    private var isWidthFlipped = false
    /// ⌘⇧\: the panel put away, the maestro given the whole window.
    private(set) var isSideHidden: Bool
    /// Called when the panel is put away or brought back; persisted by the window.
    var onSideHiddenChange: ((Bool) -> Void)?
    /// ⌘F over the maestro's terminal.
    private lazy var find: ConversationFind = {
        let find = ConversationFind()
        find.onClose = { [weak self] in self?.focusTerminal() }
        return find
    }()
    /// The one-time strip of shortcuts over the side panel's content.
    private var hint: HintStrip?

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
    private lazy var usagePill = NSView.pill([usage], flat: true)
    private let attention = NSTextField.label(font: CockpitStyle.label, color: CockpitStyle.accent)
    private lazy var attentionPill = NSView.pill([attention])
    private let model = NSTextField.label("claude", font: CockpitStyle.meta, color: CockpitStyle.text)
    private let effort = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let session = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private lazy var sessionPill = NSView.pill([session], flat: true)
    private let branch = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.code)
    private lazy var branchPill: NSView = {
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch") ?? NSImage())
        icon.contentTintColor = CockpitStyle.muted
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: CockpitStyle.iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: CockpitStyle.iconSize).isActive = true
        return NSView.pill([icon, branch], flat: true)
    }()
    /// Whether the maestro delegates or works alone; persisted by the window.
    private(set) var mode: MaestroMode
    /// The maestro was cut off mid-turn when the app last went away: its
    /// first launch here tells it to go on. Spent on that launch.
    private var resumesInterruptedWork: Bool
    /// Called with the new mode once the user has switched to it.
    var onModeChange: ((MaestroMode) -> Void)?
    /// A Cursor maestro's chat was created: its id, to be kept with the project.
    var onSessionChange: ((String) -> Void)?
    private lazy var cursorChat: String? = project.session
    /// Set while the maestro is being stopped to start again in another mode,
    /// so the shell's exit relaunches it instead of counting as a failure.
    private var relaunchPending = false
    private lazy var modeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Orquestrador", "Solo"], trackingMode: .selectOne, target: self, action: #selector(modeChosen(_:)))
        control.controlSize = .small
        control.font = CockpitStyle.meta
        // Quiet: the mode is a setting, changed rarely. The accent is kept
        // for the Terminal · Leitura switch beside it, used all the time.
        control.selectedSegmentBezelColor = CockpitStyle.raisedLine
        control.selectedSegment = mode == .solo ? 1 : 0
        control.toolTip = "Orquestrador delega a workers; Solo trabalha sozinho, sem as ferramentas de agentes"
        return control
    }()
    private lazy var modelPill = NSView.pill([model, effort], flat: true)
    /// The maestro's session name, when it has told one; what the header can
    /// hide is decided by `fitHeader`.
    private var sessionName: String?
    /// Whether there is a usage figure; the plate is shown only if it also fits.
    private var usageIsKnown = false
    private var headerWidth: CGFloat = 0
    /// Whether the project is on a branch; the plate shows only if it also fits.
    private var hasBranch = false
    /// The header row, for the tests that hold it inside its pane.
    private(set) var header: NSStackView?

    // MARK: Leitura

    /// The maestro's pane shows Leitura instead of the terminal (⌘L).
    var isReading: Bool
    /// Called when the pane switches between Terminal and Leitura; persisted.
    var onReadingChange: ((Bool) -> Void)?
    /// Made the first time it is shown; the terminal never waits on it.
    lazy var leitura: LeituraView = makeLeitura()
    lazy var readingSwitch: NSSegmentedControl = makeReadingSwitch()
    /// The switch with its words and as two icons, measured once.
    lazy var readingWidths: (full: CGFloat, compact: CGFloat) = measureReadingSwitch()

    // MARK: Bringing a surviving maestro up to the new build

    /// Where the maestro stands against the installed build.
    var updateState = MaestroUpdateState()
    let updatePill = MaestroUpdatePill()
    /// The first thing the next launch of the maestro is told, once.
    var nextLaunchPrompt: String?

    // MARK: The Fila

    /// What the maestro is told next; saved on every change when `queueStore`
    /// is set (the app), kept in memory when not (the snapshot tool).
    var promptQueue = PromptQueue()
    let queueStore: URL?
    let queueDrawer = PromptQueueDrawer()
    /// Called when the queue's length or pause changes, for the tab bar.
    var onQueueChange: (() -> Void)?
    /// A look again at a prompt held back by text in the maestro's input.
    var queueRetry: Timer?
    static let queueRetryInterval: TimeInterval = 3
    /// How long after the paste the Return goes: Claude Code takes a pasted
    /// block in as a whole before a key may submit it.
    static let submitDelay: TimeInterval = 0.25

    /// `startsTerminal: false` builds the view without a shell, a timer or an
    /// event monitor; the UI snapshot tool uses it to lay the project out
    /// offscreen. The app always starts the terminal.
    /// `showsHint` nil reads whether the shortcut hint was dismissed from the
    /// user's defaults; the snapshot tool says so outright.
    init(project: CockpitProject, kit: TerminalKit, startsTerminal: Bool = true, resumesInterruptedWork: Bool = false, showsHint: Bool? = nil) {
        self.resumesInterruptedWork = resumesInterruptedWork
        self.project = project
        self.mode = project.mode
        self.isSideHidden = project.sidePanelHidden
        self.isReading = project.isReading && project.maestro.hasReading
        self.kit = kit
        // The snapshot tool must neither read nor write the user's queues.
        self.queueStore = startsTerminal ? PromptQueueStore.directory : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.ground.cgColor
        if let queueStore { promptQueue = PromptQueueStore.load(for: project.path, in: queueStore) }
        build()
        if showsHint ?? !FirstRunHint().isDismissed { addHint() }
        applySideWidth()
        if isReading { applyReading() }
        guard startsTerminal else { return }
        restoreBrowserPages()
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
        palco.show(usageText: label?.text)
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
        palco.show(model: current)
        if isReading { leitura.sessionMayHaveChanged() }
        fitHeader()
    }

    /// Shows the session plate only when the header has room for it at its
    /// minimum width beside everything that never gives way. Decided from the
    /// header's width, not from how the layout came out, so it cannot flap.
    ///
    /// What gives way, first to last: the session name, then the usage figure
    /// (the tab bar's chip says it too once it is worth saying), and only then
    /// the path. Model, effort, "waiting for you" and branch never clip.
    func fitHeader() {
        let fit = HeaderFit.fit(width: headerWidth, headerWidths)
        // The mode switch never clips, but it can say less: at the narrowest
        // window its first segment is abbreviated.
        modeControl.setLabel(fit.abbreviatesMode ? "Orq." : "Orquestrador", forSegment: 0)
        showReadingSwitch(compact: fit.compactsReading)
        usagePill.isHidden = !fit.showsUsage
        sessionPill.isHidden = !fit.showsSession
        place.isHidden = !fit.showsPlace
        branchPill.isHidden = !fit.showsBranch
        updatePill.show(updateState.phase, compact: fit.compactsUpdate)
    }

    /// What each plate of the header takes, as `HeaderFit` reads it.
    var headerWidths: HeaderFit.Widths {
        HeaderFit.Widths(
            title: 0,
            modeFull: modeWidths.full,
            modeShort: modeWidths.short,
            readingFull: readingWidths.full,
            readingCompact: readingWidths.compact,
            model: modelPill.fittingSize.width,
            attention: attention.stringValue.isEmpty ? nil : attentionPill.fittingSize.width,
            update: updateState.phase == .current ? nil : updatePill.widths.full,
            updateCompact: updateState.phase == .current ? nil : updatePill.widths.compact,
            usage: usageIsKnown ? usagePill.fittingSize.width : nil,
            hasSession: sessionName != nil,
            branch: hasBranch ? branchPill.fittingSize.width : nil
        )
    }

    /// The mode switch with its first segment whole and abbreviated; its
    /// labels never change otherwise, so measured once.
    private lazy var modeWidths: (full: CGFloat, short: CGFloat) = {
        let current = modeControl.label(forSegment: 0)
        modeControl.setLabel("Orq.", forSegment: 0)
        let short = modeControl.fittingSize.width
        modeControl.setLabel("Orquestrador", forSegment: 0)
        let full = modeControl.fittingSize.width
        modeControl.setLabel(current ?? "Orquestrador", forSegment: 0)
        return (full, short)
    }()

    /// Hands the keyboard to the maestro.
    func focusTerminal() {
        // In Leitura, "the maestro" is the composer that talks to it.
        if isReading { return leitura.focusComposer() }
        guard let terminal else { return }
        window?.makeFirstResponder(terminal)
    }

    /// Stops or resumes drawing, for a project whose tab is not the one shown.
    /// The maestro keeps running either way.
    func setShown(_ shown: Bool) {
        terminal?.setDrawingActive(shown && !isReading)
        if isReading { leitura.setVisible(shown) }
        if shown { refreshPlace() }
        // The Git tab re-reads the repository on a timer; not for a project
        // nobody is looking at.
        if tabs.selected == .git { git.setActive(shown) }
        sharedTerminalView?.setDrawingActive(shown && tabs.selected == .terminal)
    }

    /// Whether something is running in the project's shell beyond the shell
    /// itself — the maestro, most likely.
    var isBusy: Bool { terminal?.session.isRunningProgram ?? false }

    /// Whether the maestro's shell lives in the pty-host, and so goes on
    /// when the app does not.
    var outlivesApp: Bool { maestroHost?.isInHost ?? false }

    /// Takes the project off the screen. `endingSessions` ends its shells and
    /// everything in them — closing the project. Without it, shells kept in
    /// the pty-host are only let go of, for the next app to pick up; shells
    /// in the app end, as they must.
    func shutDown(endingSessions: Bool) {
        let release: (TerminalSession?) -> Void = { session in
            endingSessions ? session?.terminate() : session?.detach()
        }
        git.setActive(false)
        sharedTerminalView?.session.onExit = nil
        release(sharedTerminalView?.session)
        sharedTerminalView?.prepareForRemoval()
        housekeeping?.invalidate()
        queueRetry?.invalidate()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        saveBrowserPages()
        browserTabs.tabs.map(\.id).forEach(browserPanel.dropBrowser(for:))
        browserPanel.clearContent()
        filesPanel.clearContent()
        isShutDown = true
        terminal?.session.onExit = nil
        release(terminal?.session)
        terminal?.prepareForRemoval()
    }

    // MARK: - The tabs of the right side

    /// Shows the workers and, on the tab, how many are running.
    func show(_ runs: [Run], now: Date) {
        workers.show(runs, now: now)
        palco.show(runs, now: now)
        if tabs.selected == .ranking { ranking.runsChanged(runs) }
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
        // Off screen, not out of the window: its page keeps running.
        if previous == .browser, tab != .browser { browserPanel.parkCurrentBrowser() }
        if previous == .git, tab != .git { git.setActive(false) }

        let content: NSView
        switch tab {
        case .palco:
            content = palco
        case .workers:
            content = workers
        case .ranking:
            content = ranking
            ranking.reload()
        case .resumo:
            content = resumo
            resumoSignature = nil
            reloadResumo()
        case .browser:
            // Opened by hand with nothing in it: a tab of the user's own.
            if browserTabs.current == nil { _ = browserTabs.openUsers(now: Date()) }
            if let id = browserTabs.current { _ = page(for: id) }
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
        if tab != previous { isWidthFlipped = false }
        applySideWidth()
    }

    // MARK: - Driving the side panel from the keyboard

    /// A tab chosen by the user — click or chord: brought back if the panel
    /// was put away, and the shared terminal given the keyboard.
    func choose(_ tab: SideTab) {
        setSideHidden(false)
        select(tab)
        if tab == .terminal, let view = sharedTerminalView { window?.makeFirstResponder(view) }
    }

    /// ⌥⌘→ and ⌥⌘←: the next tab or the one before, round the end.
    func chooseSideTab(by offset: Int) {
        let all = SideTab.allCases
        let index = all.firstIndex(of: tabs.selected) ?? 0
        choose(all[(index + offset + all.count) % all.count])
    }

    /// ⌘⇧J: the keyboard into the panel's content, so its list, diff or files
    /// can be driven without the pointer.
    func focusSidePanel() {
        setSideHidden(false)
        guard let window, let content = tabSlot.subviews.first else { return }
        if let target = Self.firstKeyTarget(in: content) {
            window.makeFirstResponder(target)
        } else {
            window.selectKeyView(following: tabs)
        }
    }

    /// The first view under `view` that takes typing or arrows: a list, a
    /// text, a page. Buttons are passed over: they take the keyboard only with
    /// full keyboard access on, and are not what "the content" means.
    private static func firstKeyTarget(in view: NSView) -> NSView? {
        for child in view.subviews where !child.isHidden {
            if child is NSTableView || child is NSTextView || child is NSCollectionView || child is TerminalView {
                return child
            }
            if child.acceptsFirstResponder, !(child is NSControl) { return child }
            if let found = firstKeyTarget(in: child) { return found }
        }
        return nil
    }

    /// ⌘\: narrow for a page, wide for a list — the other of the tab's two
    /// widths, until another tab is chosen. A panel put away comes back.
    func toggleSideWidth() {
        guard !isSideHidden else {
            setSideHidden(false)
            return
        }
        isWidthFlipped.toggle()
        applySideWidth()
    }

    /// ⌘⇧\: the panel put away, or brought back.
    func setSideHidden(_ hidden: Bool) {
        guard hidden != isSideHidden else { return }
        isSideHidden = hidden
        applySideWidth()
        onSideHiddenChange?(hidden)
        // The keyboard cannot stay in a panel nobody can see.
        if hidden, (window?.firstResponder as? NSView)?.isDescendant(of: side) == true { focusTerminal() }
    }

    /// The panel's width: its tab's share of the window, never less than a
    /// list needs; flipped (⌘\), just what a list needs.
    private var sideWidth: CGFloat {
        guard !isWidthFlipped, bounds.width > 0 else { return CockpitStyle.workersWidth }
        return max(CockpitStyle.workersWidth, (bounds.width * tabs.selected.share).rounded())
    }

    /// Follows the window: a share of it changes with it.
    override func layout() {
        if let width = sideNarrow, width.isActive, width.constant != sideWidth { width.constant = sideWidth }
        super.layout()
    }

    /// The panel put away, or at its tab's width.
    private func applySideWidth() {
        // Off before on: two held at once cannot be satisfied.
        [sideNarrow, sideCollapsed].forEach { $0?.isActive = false }
        sideNarrow?.constant = sideWidth
        (isSideHidden ? sideCollapsed : sideNarrow)?.isActive = true
        side.isHidden = isSideHidden
        divider.isHidden = isSideHidden
    }

    // MARK: - Find in the conversation

    /// ⌘F: the find bar over the maestro's terminal.
    func showFind() {
        if isReading { return leitura.showFind() }
        guard let terminal else { return }
        find.open(over: terminal, in: terminalSlot)
    }

    /// ⌘G and ⌘⇧G; the bar is opened first if it was put away.
    func findStep(forward: Bool) {
        if isReading { return leitura.findStep(forward: forward) }
        guard find.isOpen else {
            showFind()
            return
        }
        find.step(forward: forward)
    }

    /// The find bar, shown with a query, for the snapshot tool: there is no
    /// terminal to search there.
    func showFindBar(query: String, counter: String) {
        find.bar.reveal(in: terminalSlot, top: CockpitStyle.Space.md)
        find.bar.setQuery(query)
        find.bar.report(count: counter)
    }

    // MARK: - The first-run hint

    private func addHint() {
        let strip = HintStrip()
        strip.onDismiss = { [weak self] in
            FirstRunHint().dismiss()
            self?.hint?.removeFromSuperview()
            self?.hint = nil
        }
        side.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: tabsRule.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            // Goes when the strip does; the slot then falls back to the rule.
            tabSlot.topAnchor.constraint(equalTo: strip.bottomAnchor),
        ])
        hint = strip
    }

    /// The run feed changed. While the Resumo is on screen it is worked out
    /// again, half a second after the last change that matters to it; it is
    /// never worked out on a timer, nor while another tab is shown.
    func runsChanged(_ runs: [Run]) {
        var hasher = Hasher()
        for run in runs {
            hasher.combine(run.id)
            hasher.combine(String(describing: run.state))
            hasher.combine(run.rating?.score)
        }
        let signature = hasher.finalize()
        guard tabs.selected == .resumo, signature != resumoSignature else { return }
        resumoSignature = signature
        resumoReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadResumo() }
        resumoReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumoDelay, execute: work)
    }

    private func reloadResumo() {
        loadResumo? { [weak self] made in
            guard let self, self.tabs.selected == .resumo else { return }
            self.resumo.show(made)
        }
    }

    /// Comments written on deliveries, kept for the session: a review is
    /// built afresh each time it is opened, the comments outlive it.
    private let reviewBook = ReviewCommentBook()

    /// Opens a delivery's diff where files are read, the wide side area;
    /// back returns to the tab the user came from.
    func review(_ delivery: Delivery) {
        let from = tabs.selected
        let view = DiffReviewView(delivery: delivery, book: reviewBook, isSolo: mode == .solo) { [project, paneID] notes, done in
            DeliveryRedo.send(run: delivery.runID, notes: notes, project: project.path, pane: paneID, done: done)
        }
        view.onBack = { [weak self] in
            guard let self else { return }
            self.select(from)
            if from == .workers { self.workers.reveal(delivery.runID) }
        }
        select(.files)
        tabSlot.subviews.forEach { $0.removeFromSuperview() }
        tabSlot.addFilling(view)
        view.focus()
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
            do {
                let made = try makeTerminal(.shared)
                view = made.view
                sharedHost = made.hosted
            } catch {
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
        sharedHost = nil
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
        // Read before the tab opens: opening one makes it the current.
        let shown = browserTabs.current
        let isNew = browserTabs.use(id, now: Date())
        if !isNew, let kept = browserPanel.keptBrowser(for: id) {
            return (kept, false)
        }
        // New: the front tab of the browser, for when the user opens it — but
        // the panel stays on whatever they are looking at. An agent at work
        // must not pull them off it.
        let reading = tabs.selected == .browser ? shown.flatMap { $0 == id ? nil : $0 } : nil
        if reading == nil { browserTabs.show(id) }
        let view = page(for: id)
        if let reading {
            // The user is on another page of the browser: it stays in front,
            // and the new tab appears in the strip beside it.
            browserTabs.show(reading)
            _ = page(for: reading)
            refreshBrowserStrip()
        } else if tabs.selected == .browser {
            refreshBrowserStrip()
        } else {
            // Not on screen: kept in the window, so its page runs.
            browserPanel.parkCurrentBrowser()
        }
        return (view, isNew)
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
        return page(for: id)
    }

    /// The tab's browser, made if need be — and, for a tab brought back from
    /// before a restart, sent to the page it was on.
    private func page(for id: String) -> BrowserView {
        let view = browserPanel.browser(for: id)
        if let url = pendingPages.removeValue(forKey: id) { view.load(url) { _ in } }
        return view
    }

    /// The maestro's and the user's tabs as they were when the app last
    /// went away. Their pages load when each is first shown: a page is a
    /// WebKit process, not worth starting for a panel nobody opened.
    private func restoreBrowserPages() {
        guard let saved = BrowserPages.load(project: project.path) else { return }
        let now = Date()
        for (id, address) in saved.pages.sorted(by: { $0.key < $1.key }) {
            guard let url = URL(string: address), id == BrowserTabs.maestro || BrowserTabs.isUsers(id) else { continue }
            _ = browserTabs.use(id, now: now)
            pendingPages[id] = url
        }
        if let current = saved.current { browserTabs.show(current) }
    }

    /// Workers' tabs are not kept: their runs do not outlive the app.
    private func saveBrowserPages() {
        var pages: [String: String] = [:]
        for tab in browserTabs.tabs where tab.id == BrowserTabs.maestro || BrowserTabs.isUsers(tab.id) {
            let url = browserPanel.keptBrowser(for: tab.id)?.currentURL ?? pendingPages[tab.id]
            guard let url, url.scheme != "about" else { continue }
            pages[tab.id] = url.absoluteString
        }
        BrowserPages.save(.init(pages: pages, current: browserTabs.current), project: project.path)
    }

    private func showBrowserTab(_ id: String) {
        browserTabs.show(id)
        browserTabs.touch(id, now: Date())
        if tabs.selected == .browser, let current = browserTabs.current {
            _ = page(for: current)
        }
        refreshBrowserStrip()
    }

    /// An idle tab's page is let go, not the tab: it stays in the strip and
    /// loads its address again when shown or used. The page being looked at
    /// is left alone.
    private func unloadBrowserTab(_ id: String) {
        let isOnScreen = window != nil && tabs.selected == .browser && browserTabs.current == id
        guard !isOnScreen, let browser = browserPanel.keptBrowser(for: id) else { return }
        if let url = browser.currentURL, url.scheme != "about" { pendingPages[id] = url }
        browserPanel.dropBrowser(for: id)
        // Counted from now: nothing is left to let go of until it loads again.
        browserTabs.touch(id, now: Date())
    }

    /// The project left the screen, or came back to it. Its browser must
    /// not leave the window with it: out of the window a page is hidden,
    /// and what an agent started in it stops.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard tabs.selected == .browser, !isShutDown else { return }
        if window == nil {
            browserPanel.parkCurrentBrowser()
        } else if let id = browserTabs.current {
            _ = page(for: id)
        }
    }

    private func closeBrowserTab(_ id: String) {
        guard browserTabs.contains(id) else { return }
        // Let go of, not hidden: a page kept alive behind a closed tab is a
        // WebKit process holding memory for something nobody can see.
        browserPanel.dropBrowser(for: id)
        browserTabs.close(id)
        if let current = browserTabs.current {
            if tabs.selected == .browser { _ = page(for: current) }
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
                self.browserTabs.idle(now: Date()).forEach(self.unloadBrowserTab)
                self.saveBrowserPages()
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
            let (view, hosted) = try makeTerminal(.maestro)
            let session = view.session
            view.paneID = paneID
            maestroHost = hosted

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
            // Under Leitura, a fresh terminal is not drawn.
            if isReading { view.setDrawingActive(false) }

            if let hosted {
                // Only a shell that is new gets the maestro typed into it. One
                // the host kept is still running the maestro the last app
                // started, mid-turn perhaps: it was never interrupted.
                hosted.onReady = { [weak self, weak view] outcome in
                    MainActor.assumeIsolated {
                        guard let self, let view, self.terminal === view else { return }
                        if outcome == .attached {
                            self.resumesInterruptedWork = false
                            self.checkSurvivorBuild()
                        } else if launchingMaestro {
                            self.launchMaestro(in: view.session)
                        }
                    }
                }
            }
            session.start()
            if hosted == nil, launchingMaestro { launchMaestro(in: session) }
            if window != nil, !isReading { focusTerminal() }
        } catch {
            showFailure("Não deu para abrir o terminal: \(error.localizedDescription)")
        }
    }

    /// Types the line that starts the maestro into a fresh shell.
    private func launchMaestro(in session: TerminalSession) {
        // A file left by a maestro from an earlier launch is not this one's word.
        Attention.remove(for: project.path)
        if project.maestro == .cursor {
            launchCursorMaestro(in: session)
            return
        }
        guard let binary = Bundle.main.executablePath else { return }
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
                mode: mode,
                prompt: nextLaunchPrompt ?? (resumesInterruptedWork ? Maestro.resumePrompt(mode: mode) : nil),
                in: Maestro.supportDirectory
            )
            resumesInterruptedWork = false
            nextLaunchPrompt = nil
            session.send(text: line)
            maestroLaunched()
        } catch {
            // Printed, not written as a comment: zsh does not take `#`
            // as one at a prompt, and would try to run the message.
            let message = "Vitra: não deu para preparar o maestro (\(error.localizedDescription))"
            session.send(text: "printf '%s\\n' " + ShellQuote.quote(message) + "\n")
        }
    }

    /// Starts a Cursor maestro: in the project's chat when it has one, else
    /// in a chat made for it first, whose id Cursor chooses.
    private func launchCursorMaestro(in session: TerminalSession) {
        let mode = self.mode
        let prompt = nextLaunchPrompt ?? (resumesInterruptedWork ? Maestro.resumePrompt(mode: mode) : nil)
        resumesInterruptedWork = false
        nextLaunchPrompt = nil
        let start: (String, Bool) -> Void = { [weak self] chat, isNew in
            guard let self, !self.isShutDown else { return }
            do {
                let brief = try Maestro.installCursorBrief(mode: mode, in: Maestro.supportDirectory)
                session.send(text: Maestro.cursorLaunchLine(chat: chat, isNew: isNew, mode: mode, brief: brief, prompt: prompt))
                self.maestroLaunched()
            } catch {
                let message = "Vitra: não deu para preparar o maestro (\(error.localizedDescription))"
                session.send(text: "printf '%s\\n' " + ShellQuote.quote(message) + "\n")
            }
        }
        if let chat = cursorChat {
            start(chat, false)
            return
        }
        let directory = project.path
        Task { @MainActor [weak self] in
            let chat = await Task.detached { CursorChat.create(in: directory) }.value
            guard let chat else {
                let message = "Vitra: o Cursor não criou a conversa. Confira `agent status` e reabra o projeto."
                session.send(text: "printf '%s\\n' " + ShellQuote.quote(message) + "\n")
                return
            }
            self?.cursorChat = chat
            self?.onSessionChange?(chat)
            start(chat, true)
        }
    }

    /// A login shell in the project, in a terminal of its own. Both of the
    /// project's terminals are made here: the maestro's and the shared one.
    /// In the pty-host when that is on — `hosted` is then its handle there —
    /// so the shell outlives the app.
    private func makeTerminal(_ role: TerminalHosting.Role) throws -> (view: TerminalView, hosted: HostedPTY?) {
        let size = TerminalSize(columns: 80, rows: 24)
        let shell = kit.config.shell ?? ShellEnvironment.loginShell()
        let environment = ShellEnvironment.childEnvironment(
            shell: shell,
            shellIntegration: kit.config.shellIntegration,
            blockSpacing: kit.config.blockSpacing,
            colorPrompt: kit.config.colorPrompt,
            colorDefaults: kit.config.colorDefaults,
            // The pane routes tool calls back here; the project is
            // what the session hook files its conversation under.
            extra: ["VITRA_PANE": paneID, "VITRA_PROJECT": project.path]
        )
        let core = try GhosttyTerminalCore(size: size)
        let session: TerminalSession
        var hosted: HostedPTY?
        if TerminalHosting.isEnabled {
            let backend = HostedPTY(
                spec: HostedPTY.Spec(
                    id: TerminalHosting.sessionID(project: project.path, role: role),
                    executable: shell,
                    arguments: ["-l"],
                    environment: environment,
                    workingDirectory: project.path,
                    size: size
                ),
                binary: Bundle.main.executablePath
            )
            session = TerminalSession(core: core, backend: backend, size: size)
            hosted = backend
        } else {
            session = try TerminalSession(
                core: core,
                executable: shell,
                arguments: ["-l"],
                environment: environment,
                size: size,
                workingDirectory: project.path
            )
        }
        let view = try TerminalView(
            session: session,
            device: kit.device,
            fontName: kit.config.fontName,
            fontSize: CGFloat(kit.config.fontSize)
        )
        try? view.apply(kit.config)
        view.offersClose = false
        view.focusTint = CockpitStyle.accent
        view.quietsToolBlocks = true
        view.pathBase = URL(fileURLWithPath: project.path, isDirectory: true)
        view.onOpenLink = { [weak self] url, external in self?.openTerminalLink(url, external: external) }
        return (view, hosted)
    }

    /// A click in either of this project's terminals: a file into Arquivos,
    /// a folder into the file list, a page into Navegador. Command skips the
    /// panel and opens whatever it is in the system default.
    func openTerminalLink(_ url: URL, external: Bool) {
        if external {
            NSWorkspace.shared.open(url)
            return
        }
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                filesPanel.showFiles(in: url)
                filesArea.showPanel()
                select(.files)
                return
            }
            if let target = PreviewTarget.resolve(path: url.path) {
                preview(target)
            }
            return
        }
        usersBrowser().load(url) { _ in }
    }

    /// Gives the project a fresh shell, unless shells keep dying here.
    ///
    /// A shell that exits as it starts — a broken profile, say — would
    /// otherwise be replaced for ever, a new PTY and a new Metal view each
    /// time round.
    private func shellExited() {
        guard !isShutDown else { return }
        if relaunchPending {
            relaunchPending = false
            startTerminal(launchingMaestro: true)
            return
        }
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

    // MARK: - Mode

    @objc private func modeChosen(_ sender: NSSegmentedControl) {
        let chosen: MaestroMode = sender.selectedSegment == 1 ? .solo : .orchestrator
        guard chosen != mode else { return }
        // A maestro at work is restarted in the new mode; with none running
        // the mode is just noted, for the next start.
        guard isBusy, let window else {
            apply(chosen)
            return
        }
        let alert = NSAlert()
        alert.messageText = chosen == .solo ? "Trocar para Solo?" : "Trocar para Orquestrador?"
        alert.informativeText = "Trocar para \(chosen == .solo ? "Solo" : "Orquestrador") reinicia o maestro deste projeto e retoma a mesma conversa."
        alert.addButton(withTitle: "Trocar e reiniciar")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.modeControl.selectedSegment = self.mode == .solo ? 1 : 0
                return
            }
            self.apply(chosen)
            self.relaunchMaestro()
        }
    }

    private func apply(_ chosen: MaestroMode) {
        mode = chosen
        modeControl.selectedSegment = chosen == .solo ? 1 : 0
        onModeChange?(chosen)
        fitHeader()
    }

    /// Ends the project's shell, and the maestro in it, the way closing the
    /// project does; its exit starts a fresh shell and the maestro again, in
    /// the current mode, resuming the conversation it was in.
    func relaunchMaestro() {
        guard let terminal else {
            startTerminal(launchingMaestro: true)
            return
        }
        relaunchPending = true
        terminal.session.terminate()
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
        hasBranch = branch != nil
        palco.setBranch(branch)
        fitHeader()
    }

    // MARK: - Layout

    private func build() {
        // Each fact on a plate of its own: which model and how hard it is
        // thinking, how much of the week is spent, and on the far side where
        // the project is and on which branch.
        effort.isHidden = true
        modelPill.toolTip = "Modelo e effort do maestro"
        usagePill.isHidden = true
        attentionPill.isHidden = true
        attentionPill.toolTip = "O maestro parou e espera por você"
        for view in [usage, attention, model, effort, branch, modelPill, usagePill, attentionPill, branchPill] as [NSView] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // What gives way, in this order: the path (head-truncated, lowest
        // priority), then the session name, which truncates down to a minimum
        // width and is hidden below it — never drawn as an empty plate. The
        // model, effort, usage and branch plates never clip. Both sit below
        // the header's clipping resistance (250): the row truncates them
        // before it would rather clip off its far end.
        place.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(230), for: .horizontal)
        place.widthAnchor.constraint(greaterThanOrEqualToConstant: HeaderFit.placeMinWidth).isActive = true
        session.lineBreakMode = .byTruncatingTail
        session.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        session.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionPill.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        sessionPill.widthAnchor.constraint(greaterThanOrEqualToConstant: HeaderFit.sessionMinWidth).isActive = true
        sessionPill.isHidden = true
        modeControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        updatePill.onUpdate = { [weak self] in self?.updateMaestro(asking: true) }
        updatePill.onCancel = { [weak self] in self?.cancelArmedUpdate() }
        readingSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Left to right: what you switch, then what is true now (model, week,
        // session — one quiet line, no box each), then what needs you, which
        // alone is boxed. The mode switch names the mode: no title repeats it.
        let header = MaestroHeader(views: [modeControl, readingSwitch, modelPill, usagePill, sessionPill, attentionPill, updatePill, NSView(), place, branchPill])
        self.header = header
        header.spacing = CockpitStyle.Space.md
        // The header never widens its pane: it would push the side panel off
        // the window. It clips for the instant before `fitHeader`, told the
        // real width, hides what does not fit.
        header.setClippingResistancePriority(.defaultLow, for: .horizontal)
        header.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.inset)
        header.onResize = { [weak self] width in
            self?.headerWidth = width
            self?.fitHeader()
        }
        refreshPlace()

        let headerRule = NSView.rule(CockpitStyle.softLine)
        buildQueueDrawer()
        for view in [header, headerRule, queueDrawer, terminalSlot, divider, side] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [tabs, tabsRule, tabSlot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(view)
        }
        tabs.onSelect = { [weak self] tab in self?.choose(tab) }
        tabSlot.addFilling(workers)
        workers.onReview = { [weak self] delivery in self?.review(delivery) }
        // A provider's login or install command, typed into the shared
        // terminal as terminal_run would; not into a program already running.
        resumo.onRunCommand = { [weak self] command in
            guard let self, let session = try? self.sharedTerminal(showing: true), !session.isRunningProgram else { return false }
            session.send(text: command + "\n")
            return true
        }

        // The right side takes its tab's share of the window (`sideWidth`),
        // kept up to date in `layout()`.
        let narrow = side.widthAnchor.constraint(equalToConstant: CockpitStyle.workersWidth)
        let collapsed = side.widthAnchor.constraint(equalToConstant: 0)
        (sideNarrow, sideCollapsed) = (narrow, collapsed)
        // Under the tabs' rule, unless the hint strip sits there first.
        let slotUnderRule = tabSlot.topAnchor.constraint(equalTo: tabsRule.bottomAnchor)
        slotUnderRule.priority = .fittingSizeCompression

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
            slotUnderRule,
            tabSlot.topAnchor.constraint(greaterThanOrEqualTo: tabsRule.bottomAnchor),
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

            queueDrawer.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            queueDrawer.leadingAnchor.constraint(equalTo: leadingAnchor),
            queueDrawer.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            terminalSlot.topAnchor.constraint(equalTo: queueDrawer.bottomAnchor),
            terminalSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalSlot.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            terminalSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

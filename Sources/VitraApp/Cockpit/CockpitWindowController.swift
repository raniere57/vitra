import AppKit
import VitraBridge
import VitraCore
import VitraOrchestrator
import VitraPanel

/// The cockpit's one window: a tab per project, and the project shown under them.
final class CockpitWindowController: NSWindowController, NSWindowDelegate {
    static let minSize = NSSize(width: 980, height: 600)

    private let kit: TerminalKit
    private let feed: RunFeed
    private let store: URL

    private let tabBar = CockpitTabBar()
    private let stage = NSView()
    private lazy var welcome = WelcomeView(target: self, action: #selector(openProject(_:)))

    private var projects: [CockpitProject]
    private var views: [String: ProjectView] = [:]
    private var selected = 0
    private var runs: [Run] = []
    private var usageWatch: DispatchSourceFileSystemObject?
    private var usageDebounce: DispatchWorkItem?
    /// What each started project's maestro last said about waiting on the user.
    private var attention: [String: AttentionRecord] = [:]
    private let throttle = AttentionThrottle()
    private let alerts = AttentionAlerts()
    private var attentionTick: DispatchWorkItem?
    /// The longest a waiting label goes without being redrawn.
    private static let attentionTickLimit: TimeInterval = 30

    init(kit: TerminalKit, feed: RunFeed, store: URL = CockpitState.defaultURL) {
        self.kit = kit
        self.feed = feed
        self.store = store
        // Kept even when its folder is missing right now: a project on a drive
        // that is not mounted today is still the user's project, and dropping
        // it here would erase it from the saved list at the next change.
        let saved = CockpitState.load(from: store)
        projects = saved.projects
        selected = saved.selected

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Vitra"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = CockpitStyle.ground
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = Self.minSize
        window.setFrameAutosaveName("VitraCockpit")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self

        build()
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.onClose = { [weak self] in self?.close(at: $0) }
        tabBar.onAdd = { [weak self] in self?.openProject(nil) }
        feed.onChange = { [weak self] runs in self?.show(runs) }
        alerts.onOpen = { [weak self] path in
            guard let self, let index = projects.firstIndex(where: { $0.path == path }) else { return }
            self.window?.makeKeyAndOrderFront(nil)
            select(index)
        }
        // Covered, minimised, on another space or hidden with the app: the
        // window's own word for "nobody is looking", and the feed stops
        // reading the runs until somebody is.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        watchUsage()
        select(selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Projects

    @objc func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Abrir projeto"
        panel.message = "Escolha a pasta do projeto. O maestro trabalha a partir dela."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        projects = CockpitProjects.adding(url.path, to: projects)
        save()
        let opened = CockpitProject(path: url.path)
        select(projects.firstIndex { $0.path == opened.path } ?? projects.count - 1)
    }

    /// Closes the page or file open beside the project on screen; with none
    /// open, the project; with no project, the window.
    @objc func closeProject(_ sender: Any?) {
        guard projects.indices.contains(selected) else {
            window?.performClose(sender)
            return
        }
        if views[projects[selected].path]?.closeSidePanel() == true { return }
        close(at: selected)
    }

    /// Brings a tab of the right side to the front, in the project on screen.
    /// The menu item's tag says which.
    @objc func showSideTab(_ sender: NSMenuItem) {
        guard SideTab.allCases.indices.contains(sender.tag) else { return }
        current?.choose(SideTab.allCases[sender.tag])
    }

    @objc func nextSideTab(_ sender: Any?) { current?.chooseSideTab(by: 1) }
    @objc func previousSideTab(_ sender: Any?) { current?.chooseSideTab(by: -1) }
    @objc func focusMaestro(_ sender: Any?) { current?.focusTerminal() }
    @objc func focusSidePanel(_ sender: Any?) { current?.focusSidePanel() }
    @objc func toggleSideWidth(_ sender: Any?) { current?.toggleSideWidth() }

    @objc func toggleSidePanel(_ sender: Any?) {
        guard let current else { return }
        current.setSideHidden(!current.isSideHidden)
    }

    @objc func findInConversation(_ sender: Any?) { current?.showFind() }
    @objc func findNextInConversation(_ sender: Any?) { current?.findStep(forward: true) }
    @objc func findPreviousInConversation(_ sender: Any?) { current?.findStep(forward: false) }

    /// ⌘/: every chord, as a sheet over the window.
    @objc func showShortcuts(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        window.beginSheet(ShortcutsSheet.makeWindow()) { _ in }
    }

    /// The project on screen, once its view is made.
    private var current: ProjectView? {
        projects.indices.contains(selected) ? views[projects[selected].path] : nil
    }

    @objc func nextProject(_ sender: Any?) { step(by: 1) }
    @objc func previousProject(_ sender: Any?) { step(by: -1) }

    /// Shows the project the menu item's tag names, counting from zero.
    @objc func showProject(_ sender: NSMenuItem) {
        if projects.indices.contains(sender.tag) { select(sender.tag) }
    }

    private func step(by offset: Int) {
        guard projects.count > 1 else { return }
        select((selected + offset + projects.count) % projects.count)
    }

    private func close(at index: Int) {
        guard projects.indices.contains(index) else { return }
        // Closing ends the shell and whatever conversation the maestro is in;
        // one stray Cmd-W should not be able to do that unasked.
        if views[projects[index].path]?.isBusy == true {
            let alert = NSAlert()
            alert.messageText = "Fechar \(projects[index].name)?"
            alert.informativeText = "O maestro deste projeto ainda está rodando. Fechar encerra a conversa dele. Workers já delegados continuam."
            alert.addButton(withTitle: "Fechar projeto")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let project = projects.remove(at: index)
        // The one place a project's shells really end; quitting only lets go.
        views.removeValue(forKey: project.path)?.shutDown(endingSessions: true)
        save()
        select(min(selected > index ? selected - 1 : selected, projects.count - 1))
    }

    private func select(_ index: Int) {
        selected = max(index, 0)
        stage.subviews.forEach { $0.removeFromSuperview() }
        views.values.forEach { $0.setShown(false) }

        guard projects.indices.contains(selected) else {
            stage.addFilling(welcome)
            refresh()
            return
        }
        // The maestro's conversation is given its id before the maestro starts
        // and written down at once, so it is there to resume even if the app
        // does not get to quit cleanly.
        if projects[selected].session == nil {
            projects[selected].session = UUID().uuidString.lowercased()
        }
        // Which tab is in front is part of what reopening puts back.
        save()
        let project = projects[selected]
        // A project's shell starts the first time its tab is shown, not at
        // launch: ten remembered projects should not mean ten maestros.
        let view = views[project.path] ?? makeView(project)
        stage.addFilling(view)
        view.setShown(true)
        view.focusTerminal()
        refresh()
    }

    private func makeView(_ project: CockpitProject) -> ProjectView {
        // Spent only if the maestro has to be started again; a maestro the
        // pty-host kept was never interrupted. The attention file is cleared
        // at that start too: a kept maestro's file is still its word.
        let wasInterrupted = Attention.takeInterrupted(for: project.path)
        let view = ProjectView(project: project, kit: kit, resumesInterruptedWork: wasInterrupted)
        view.workers.onStopAll = { [weak self] ids in self?.feed.cancel(ids) }
        view.loadRanking = { [weak self] done in self?.feed.scores(done) }
        view.loadResumo = { [weak self] done in self?.feed.resumo(for: project, done) }
        view.onModeChange = { [weak self] mode in
            guard let self, let index = self.projects.firstIndex(where: { $0.path == project.path }) else { return }
            self.projects[index].mode = mode
            self.save()
        }
        view.onSideHiddenChange = { [weak self] hidden in
            guard let self, let index = self.projects.firstIndex(where: { $0.path == project.path }) else { return }
            self.projects[index].sidePanelHidden = hidden
            self.save()
        }
        views[project.path] = view
        return view
    }

    private func save() {
        do {
            try CockpitState(projects: projects, selected: selected).save(to: store)
        } catch {
            // The tabs still work for this launch; they just will not be
            // remembered, and the user should know why.
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Tools

    /// Lets go of every project's shell, for when the app is going away.
    /// Shells in the pty-host go on; shells in the app end with it.
    func shutDown() {
        // Before the shells end: ending them ends the maestros, whose last
        // hook takes their state away. Only those that do end were cut off.
        Attention.markInterrupted(projects: views.filter { !$0.value.outlivesApp }.map(\.key))
        views.values.forEach { $0.shutDown(endingSessions: false) }
        views = [:]
    }

    /// Ends every project's shell, wherever it lives, deliberately: nothing
    /// is noted as interrupted.
    func endAllSessions() {
        views.values.forEach { $0.shutDown(endingSessions: true) }
        views = [:]
    }

    /// The project a tool call belongs to — never brought to the front.
    ///
    /// The one whose shell the call came from, when the helper could say; a
    /// call with no pane is a helper started outside the cockpit, and gets the
    /// project on screen. The user stays where they are: an agent opening a
    /// page in another project must not pull them out of the one they are
    /// working in. What it opened is there when they go and look.
    private func project(for pane: String?) throws -> ProjectView {
        if let pane, let view = views.values.first(where: { $0.paneID == pane }) {
            return view
        }
        guard projects.indices.contains(selected), let view = views[projects[selected].path] else {
            throw ToolError("Vitra has no project open")
        }
        return view
    }

    // MARK: - Workers

    private func show(_ runs: [Run]) {
        self.runs = runs
        refresh()
        if projects.indices.contains(selected) { views[projects[selected].path]?.runsChanged(runs) }
    }

    private func refresh() {
        let now = Date()
        let usage = MaestroStatus.load()
        tabBar.show(tabs(now: now), selected: selected)
        tabBar.show(chips: ProviderChips.derive(runs: runs, usage: usage, now: now))
        tabBar.show(costToday: WorkerBoard.totals(runs, since: Calendar.current.startOfDay(for: now)).cost)
        // Only the project on screen is redrawn; the others catch up when shown.
        if projects.indices.contains(selected), let view = views[projects[selected].path] {
            view.show(usage: MaestroStatus.label(usage, now: now))
            view.show(model: MaestroStatus.model(for: projects[selected].path))
            view.show(attention: AttentionPolicy.label(attention[projects[selected].path], now: now))
            view.show(WorkerBoard.runs(runs, in: projects[selected]), now: now)
        }
        scheduleAttentionTick(now: now)
    }

    private func tabs(now: Date) -> [CockpitTabBar.Tab] {
        projects.map {
            CockpitTabBar.Tab(
                name: $0.name,
                running: WorkerBoard.runningCount(WorkerBoard.runs(runs, in: $0)),
                callsForYou: AttentionPolicy.isCalling(attention[$0.path], now: now)
            )
        }
    }

    // MARK: - Waiting for the user

    /// Reads each started project's attention file, alerts on a new wait, and
    /// redraws the labels. Small files, no run list: cheap enough to follow
    /// every write to the maestro folder.
    private func refreshAttention() {
        let now = Date()
        var records: [String: AttentionRecord] = [:]
        for project in projects where views[project.path] != nil {
            records[project.path] = Attention.load(for: project.path)
        }
        attention = records

        // Typing in that project's terminal: the app is in front, on that tab.
        let isInFront = NSApp.isActive && window?.isKeyWindow == true
        for (index, project) in projects.enumerated() {
            guard let record = records[project.path] else {
                _ = throttle.shouldAlert(project: project.path, state: nil, now: now, isWatching: false)
                continue
            }
            let isWatching = isInFront && index == selected
            if throttle.shouldAlert(project: project.path, state: record.state, now: now, isWatching: isWatching) {
                alerts.alert(project: project.path, name: project.name, body: AttentionPolicy.body(record))
            }
        }
        showAttention(now: now)
    }

    /// Redraws what depends on the attention records and the clock.
    private func showAttention(now: Date) {
        tabBar.show(tabs(now: now), selected: selected)
        if projects.indices.contains(selected), let view = views[projects[selected].path] {
            view.show(attention: AttentionPolicy.label(attention[projects[selected].path], now: now))
        }
        let calling = projects.filter { AttentionPolicy.isCalling(attention[$0.path], now: now) }.count
        NSApp.dockTile.badgeLabel = calling > 0 ? "\(calling)" : nil
        scheduleAttentionTick(now: now)
    }

    /// One look at the clock when it next matters: when a fresh wait crosses
    /// into calling, and every so often to keep the "há quanto tempo" honest.
    /// Nothing is scheduled while nobody waits or nobody can see the window.
    private func scheduleAttentionTick(now: Date) {
        attentionTick?.cancel()
        attentionTick = nil
        guard window?.occlusionState.contains(.visible) == true else { return }
        let waiting = projects.compactMap { attention[$0.path] }.filter { $0.state != .working }
        guard !waiting.isEmpty else { return }
        let untilCalling = waiting.compactMap { AttentionPolicy.untilCalling($0, now: now) }.min()
        let delay = min(untilCalling ?? Self.attentionTickLimit, Self.attentionTickLimit)
        let work = DispatchWorkItem { [weak self] in self?.showAttention(now: Date()) }
        attentionTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Usage and model labels only: the maestro folder is rewritten many times
    /// a minute, and rebuilding the worker board from that would be the whole
    /// cockpit redrawing for a percentage that changed.
    private func refreshMaestroStatus() {
        guard projects.indices.contains(selected), let view = views[projects[selected].path] else { return }
        let now = Date()
        let usage = MaestroStatus.load()
        view.show(usage: MaestroStatus.label(usage, now: now))
        view.show(model: MaestroStatus.model(for: projects[selected].path))
        tabBar.show(chips: ProviderChips.derive(runs: runs, usage: usage, now: now))
    }

    /// Redraws the usage figure whenever the maestro's status line writes a
    /// new one. A watch on the folder, not a timer: the file is replaced
    /// whole each time, and nothing needs to run between replacements.
    /// Writes are coalesced: usage.json and model-* land as several atomic
    /// replaces in a burst, and one refresh half a second later is enough.
    private func watchUsage() {
        let folder = Maestro.supportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.usageWrote() }
        // Darwin's close: inside a window controller a bare `close` is the window's.
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        usageWatch = source
    }

    private func usageWrote() {
        usageDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.usageDebounce = nil
            self?.refreshMaestroStatus()
            self?.refreshAttention()
        }
        usageDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Window

    @objc private func occlusionChanged(_ notification: Notification) {
        feed.setVisible(window?.occlusionState.contains(.visible) ?? false)
        showAttention(now: Date())
    }

    func windowWillClose(_ notification: Notification) {
        attentionTick?.cancel()
        attentionTick = nil
        usageDebounce?.cancel()
        usageDebounce = nil
        feed.setVisible(false)
        usageWatch?.cancel()
        usageWatch = nil
        shutDown()
        stage.subviews.forEach { $0.removeFromSuperview() }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = CockpitStyle.ground.cgColor

        for view in [tabBar, stage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: CockpitStyle.barHeight),
            stage.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}

extension CockpitWindowController: NSMenuItemValidation {
    /// What needs a project is greyed out without one; "Projeto 7" without a
    /// seventh. The panel item says which way it goes.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openProject(_:)), #selector(closeProject(_:)), #selector(showShortcuts(_:)):
            return true
        case #selector(showProject(_:)):
            return projects.indices.contains(item.tag)
        case #selector(nextProject(_:)), #selector(previousProject(_:)):
            return projects.count > 1
        case #selector(toggleSidePanel(_:)):
            item.title = current?.isSideHidden == true ? "Mostrar o painel" : "Ocultar o painel"
            return current != nil
        default:
            return current != nil
        }
    }
}

extension CockpitWindowController: ToolHost {
    func preview(_ target: PreviewTarget, pane: String?) throws {
        try project(for: pane).preview(target)
    }

    func browser(pane: String?, agent: String?) throws -> BrowserView {
        let (index, view) = try locate(pane)
        let (browser, isNew) = view.browser(agent: agent)
        // A tab that just opened is worth showing. One already open is being
        // worked in, and its project stays wherever the user left it.
        if isNew {
            if index != selected { select(index) }
            window?.orderFront(nil)
        }
        return browser
    }

    func browser(pane: String?, tab: String) throws -> BrowserView {
        try locate(pane).view.browser(tab: tab)
    }

    func sharedTerminal(pane: String?, showing: Bool) throws -> TerminalSession {
        try locate(pane).view.sharedTerminal(showing: showing)
    }

    func browserTabs(pane: String?, agent: String?) throws -> [String] {
        try locate(pane).view.browserTabList(agent: agent)
    }

    /// The project a call came from — the one on screen for a call that names
    /// none — without bringing it forward.
    private func locate(_ pane: String?) throws -> (index: Int, view: ProjectView) {
        let index = pane.flatMap { id in projects.firstIndex { views[$0.path]?.paneID == id } } ?? selected
        guard projects.indices.contains(index), let view = views[projects[index].path] else {
            throw ToolError("Vitra has no project open")
        }
        return (index, view)
    }
}

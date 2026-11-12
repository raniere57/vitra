import AppKit
import VitraBridge
import VitraCore
import VitraOrchestrator
import VitraPanel

/// The cockpit's one window: a tab per project, and the project shown under them.
final class CockpitWindowController: NSWindowController, NSWindowDelegate {
    static let minSize = NSSize(width: 980, height: 600)
    private static let filledOnceKey = "cockpitFilledScreenOnce"

    private let kit: TerminalKit
    private let feed: RunFeed
    private let store: URL

    private let tabBar = CockpitTabBar()
    private let stage = NSView()
    /// Under everything, never shown: where every project's browsers wait
    /// while off screen, still in the window so their pages keep running.
    private let browserParking = NSView()
    private lazy var welcome = WelcomeView(target: self, action: #selector(openProject(_:)))

    private var projects: [CockpitProject]
    /// Closed lately, newest first: what the "+" offers back.
    private var closed: [CockpitProject]
    private lazy var sleeping = SleepingView(target: self, action: #selector(wakeProject(_:)))
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
        closed = (saved.closed ?? []).filter { closed in !saved.projects.contains { $0.path == closed.path } }

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
        // By default the cockpit fills the screen — the whole visible area,
        // under the menu bar and beside the Dock — as a plain window, not in
        // full screen: all the room, and still free to be moved and resized.
        // Applied once, so a size the user chose afterwards is the one kept.
        if !UserDefaults.standard.bool(forKey: Self.filledOnceKey),
           let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
            UserDefaults.standard.set(true, forKey: Self.filledOnceKey)
        } else if window.frame.origin == .zero {
            window.center()
        }
        super.init(window: window)
        window.delegate = self

        build()
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.onClose = { [weak self] in self?.close(at: $0) }
        tabBar.onAdd = { [weak self] in self?.openProject(nil) }
        tabBar.onReopen = { [weak self] in self?.open($0) }
        tabBar.onSleep = { [weak self] in self?.sleep(at: $0) }
        tabBar.onReveal = { [weak self] index in
            guard let self, self.projects.indices.contains(index) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: self.projects[index].path)])
        }
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
        // A project left asleep stays asleep through a relaunch.
        select(selected, waking: false)
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
        open(url.path)
    }

    /// Opens the project at `path`, as it was when it was closed if it is
    /// remembered: the same conversation, mode and panel.
    private func open(_ path: String) {
        let opened = CockpitProject(path: path, isReading: true)
        if let index = closed.firstIndex(where: { $0.path == opened.path }) {
            let remembered = closed.remove(at: index)
            if !projects.contains(where: { $0.path == remembered.path }) { projects.append(remembered) }
        } else {
            projects = CockpitProjects.adding(path, to: projects)
        }
        save()
        select(projects.firstIndex { $0.path == opened.path } ?? projects.count - 1)
    }

    /// Puts the project on screen to sleep, or the one a tab's menu named.
    @objc func sleepProject(_ sender: Any?) { sleep(at: selected) }

    @objc func wakeProject(_ sender: Any?) { select(selected) }

    /// Ends everything the project runs — maestro, shells, pages — and keeps
    /// its tab: a click on it starts the maestro again in the same conversation.
    private func sleep(at index: Int) {
        guard projects.indices.contains(index) else { return }
        if projects[index].isAsleep {
            select(index)
            return
        }
        if views[projects[index].path]?.isBusy == true {
            let alert = NSAlert()
            alert.messageText = "Suspender \(projects[index].name)?"
            alert.informativeText = "O maestro deste projeto ainda está rodando. Suspender o encerra; a conversa fica guardada e volta ao clicar na aba. Workers já delegados continuam."
            alert.addButton(withTitle: "Suspender projeto")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        projects[index].isAsleep = true
        let path = projects[index].path
        views.removeValue(forKey: path)?.shutDown(endingSessions: true)
        attention[path] = nil
        guard index == selected else {
            save()
            refresh()
            return
        }
        // Somewhere already running, if there is one; nothing is woken for it.
        let awake = projects.map { views[$0.path] != nil }
        select(CockpitProjects.nearestAwake(to: index, awake: awake) ?? index, waking: false)
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
    /// ⌘L: the maestro's pane as the terminal or as Leitura.
    @objc func toggleReading(_ sender: Any?) { current?.toggleReading() }

    @objc func toggleSidePanel(_ sender: Any?) {
        guard let current else { return }
        current.setSideHidden(!current.isSideHidden)
    }

    @objc func findInConversation(_ sender: Any?) { current?.showFind() }
    @objc func findNextInConversation(_ sender: Any?) { current?.findStep(forward: true) }
    @objc func findPreviousInConversation(_ sender: Any?) { current?.findStep(forward: false) }

    /// ⇧⌘⏎: the Fila of the project on screen, open, its field ready.
    @objc func addToQueue(_ sender: Any?) { current?.openQueue() }

    /// Every opened project's maestro that runs an older build: restarted
    /// now if it waits, armed to restart when its turn ends if it works.
    @objc func updateAllMaestros(_ sender: Any?) {
        views.values.filter(\.isOutdated).forEach { $0.updateMaestro(asking: false) }
    }

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
        // Passing by a sleeping project does not wake it.
        select((selected + offset + projects.count) % projects.count, waking: false)
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
        closed = CockpitProjects.remembering(project, in: closed)
        // The one place a project's shells really end; quitting only lets go.
        views.removeValue(forKey: project.path)?.shutDown(endingSessions: true)
        save()
        select(min(selected > index ? selected - 1 : selected, projects.count - 1))
    }

    private func select(_ index: Int, waking: Bool = true) {
        selected = max(index, 0)
        stage.subviews.forEach { $0.removeFromSuperview() }
        views.values.forEach { $0.setShown(false) }

        guard projects.indices.contains(selected) else {
            stage.addFilling(welcome)
            refresh()
            return
        }
        if projects[selected].isAsleep {
            guard waking else {
                save()
                sleeping.show(projects[selected].name)
                stage.addFilling(sleeping)
                refresh()
                return
            }
            projects[selected].isAsleep = false
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
        view.browserParking = browserParking
        view.workers.onStopAll = { [weak self] ids in self?.feed.cancel(ids) }
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
        view.onReadingChange = { [weak self] reading in
            guard let self, let index = self.projects.firstIndex(where: { $0.path == project.path }) else { return }
            self.projects[index].isReading = reading
            self.save()
        }
        view.onQueueChange = { [weak self] in
            guard let self else { return }
            self.tabBar.show(self.tabs(now: Date()), selected: self.selected)
        }
        // What the maestro is doing as the project opens is where its next
        // change is measured from: a turn already running when the app
        // started still ends in a send.
        attention[project.path] = Attention.load(for: project.path)
        views[project.path] = view
        return view
    }

    private func save() {
        do {
            try CockpitState(projects: projects, selected: selected, closed: closed).save(to: store)
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
        // A call that names a project which is not open goes nowhere: landing
        // in whatever is on screen would put one project's page in another.
        if let pane { throw ToolError("the project this call came from (\(pane)) is not open in Vitra") }
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
        tabBar.show(recent: closed.map(\.path))
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
        // The project in front of the user is seen as it stands.
        if window?.isKeyWindow == true, projects.indices.contains(selected) {
            seenAt[projects[selected].path] = now
        }
        return projects.map {
            let record = attention[$0.path]
            return CockpitTabBar.Tab(
                name: $0.name,
                running: WorkerBoard.runningCount(WorkerBoard.runs(runs, in: $0)),
                callsForYou: record?.state == .needsPermission,
                maestroWorking: record?.state == .working,
                finishedUnseen: AttentionPolicy.isUnseen(record, seen: seenAt[$0.path], now: now),
                queued: views[$0.path]?.promptQueue.count ?? 0,
                isAsleep: $0.isAsleep,
                path: $0.path
            )
        }
    }

    /// When the user last had each project in front of them, so that a turn
    /// that ended is news only until it has been looked at.
    private var seenAt: [String: Date] = [:]

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
        let previous = attention
        attention = records
        // A change of state is news to the project: the end of a turn is when
        // an armed update and the Fila act. The same state read again is not.
        for (path, view) in views where previous[path]?.state != records[path]?.state {
            view.attentionChanged(from: previous[path]?.state, to: records[path]?.state)
        }

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
        let descriptor = Darwin.open(folder.path, O_EVTONLY)
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

    /// Coming back to the window is looking at the project in front.
    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
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

        browserParking.frame = content.bounds
        browserParking.autoresizingMask = [.width, .height]
        content.addSubview(browserParking, positioned: .below, relativeTo: nil)
        // What covers the lot must be solid, whatever a project draws.
        stage.wantsLayer = true
        stage.layer?.backgroundColor = CockpitStyle.bar.cgColor
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
        case #selector(sleepProject(_:)):
            let asleep = projects.indices.contains(selected) && projects[selected].isAsleep
            item.title = asleep ? "Retomar projeto" : "Suspender projeto"
            return projects.indices.contains(selected)
        case #selector(showProject(_:)):
            return projects.indices.contains(item.tag)
        case #selector(nextProject(_:)), #selector(previousProject(_:)):
            return projects.count > 1
        case #selector(updateAllMaestros(_:)):
            return views.values.contains(where: \.isOutdated)
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
        // An agent opening a page never moves the user: not to its project,
        // not to the front. The page is there when they go and look.
        try locate(pane).view.browser(agent: agent).0
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
        let named = pane.flatMap { id in projects.firstIndex { views[$0.path]?.paneID == id } }
        if let pane, named == nil { throw ToolError("the project this call came from (\(pane)) is not open in Vitra") }
        let index = named ?? selected
        guard projects.indices.contains(index), let view = views[projects[index].path] else {
            throw ToolError("Vitra has no project open")
        }
        return (index, view)
    }
}

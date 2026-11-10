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
    private let welcome = NSStackView()

    private var projects: [CockpitProject]
    private var views: [String: ProjectView] = [:]
    private var selected = 0
    private var runs: [Run] = []
    private var usageWatch: DispatchSourceFileSystemObject?
    private var usageDebounce: DispatchWorkItem?

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
        guard projects.indices.contains(selected), SideTab.allCases.indices.contains(sender.tag) else { return }
        views[projects[selected].path]?.select(SideTab.allCases[sender.tag])
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
        views.removeValue(forKey: project.path)?.shutDown()
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
        let view = ProjectView(project: project, kit: kit)
        view.workers.onStopAll = { [weak self] ids in self?.feed.cancel(ids) }
        view.loadRanking = { [weak self] done in self?.feed.scores(done) }
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

    /// Ends every project's shell, for when the app is going away.
    func shutDown() {
        views.values.forEach { $0.shutDown() }
        views = [:]
    }

    /// The project a tool call belongs to, brought to the front.
    ///
    /// The one whose shell the call came from, when the helper could say; a
    /// call with no pane is a helper started outside the cockpit, and gets the
    /// project on screen. Either way the project is shown: what a tool opens
    /// is for the user to see, and a page loading in a tab nobody is looking
    /// at reads as "the agent says it opened but nothing is here".
    private func project(for pane: String?) throws -> ProjectView {
        let index = pane.flatMap { id in projects.firstIndex { views[$0.path]?.paneID == id } }
        if let index, index != selected { select(index) }
        guard projects.indices.contains(selected), let view = views[projects[selected].path] else {
            throw ToolError("Vitra has no project open")
        }
        window?.orderFront(nil)
        return view
    }

    // MARK: - Workers

    private func show(_ runs: [Run]) {
        self.runs = runs
        refresh()
    }

    private func refresh() {
        let now = Date()
        tabBar.show(
            projects.map { CockpitTabBar.Tab(name: $0.name, running: WorkerBoard.runningCount(WorkerBoard.runs(runs, in: $0))) },
            selected: selected
        )
        tabBar.show(costToday: WorkerBoard.totals(runs, since: Calendar.current.startOfDay(for: now)).cost)
        // Only the project on screen is redrawn; the others catch up when shown.
        if projects.indices.contains(selected), let view = views[projects[selected].path] {
            view.show(usage: MaestroStatus.label(MaestroStatus.load(), now: now))
            view.show(model: MaestroStatus.model(for: projects[selected].path))
            view.show(WorkerBoard.runs(runs, in: projects[selected]), now: now)
        }
    }

    /// Usage and model labels only: the maestro folder is rewritten many times
    /// a minute, and rebuilding the worker board from that would be the whole
    /// cockpit redrawing for a percentage that changed.
    private func refreshMaestroStatus() {
        guard projects.indices.contains(selected), let view = views[projects[selected].path] else { return }
        let now = Date()
        view.show(usage: MaestroStatus.label(MaestroStatus.load(), now: now))
        view.show(model: MaestroStatus.model(for: projects[selected].path))
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
        }
        usageDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Window

    @objc private func occlusionChanged(_ notification: Notification) {
        feed.setVisible(window?.occlusionState.contains(.visible) ?? false)
    }

    func windowWillClose(_ notification: Notification) {
        usageDebounce?.cancel()
        usageDebounce = nil
        feed.setVisible(false)
        usageWatch?.cancel()
        usageWatch = nil
        views.values.forEach { $0.shutDown() }
        views = [:]
        stage.subviews.forEach { $0.removeFromSuperview() }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = CockpitStyle.ground.cgColor

        let headline = NSTextField.label("Abra seu primeiro projeto", font: CockpitStyle.ui(22, .semibold), color: CockpitStyle.text)
        let body = NSTextField(wrappingLabelWithString: "Cada aba é uma pasta. Nela, o maestro planeja o trabalho e delega as partes a modelos mais baratos.")
        body.font = CockpitStyle.ui(13)
        body.textColor = CockpitStyle.muted
        body.alignment = .center
        body.preferredMaxLayoutWidth = 380
        let open = NSButton(title: "Abrir projeto", target: self, action: #selector(openProject(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .large
        open.keyEquivalent = "\r"
        welcome.orientation = .vertical
        welcome.spacing = 12
        welcome.setViews([headline, body, open], in: .center)
        welcome.setCustomSpacing(20, after: body)

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

import AppKit
import Metal
import VitraBridge
import VitraCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var device: MTLDevice?
    private let attachments = AttachmentStore()

    /// Files handed to the app before it had a window to show them in.
    private var pendingPreviews: [URL] = []

    private let bookmarkStore = BookmarkStore()
    private(set) var bookmarks: [Bookmark] = []
    private let palette = FolderPalette()
    private let foldersWindow = FoldersWindow()

    private var bridge: SocketServer?
    private var configWatcher: ConfigWatcher?
    private let preferences = PreferencesWindow()
    private(set) var config = Config()

    /// The window MCP tools act on.
    var frontController: TerminalWindowController? { currentController }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("Vitra needs a Metal-capable GPU.")
            return
        }
        self.device = device

        // Attachments are written for one conversation; sweep last week's on the
        // way in, off the main thread so it never delays the first window.
        let store = attachments
        DispatchQueue.global(qos: .utility).async { store.purgeExpired() }

        loadConfiguration()
        bookmarks = bookmarkStore.load()
        rebuildMenu()
        if pendingPreviews.isEmpty, !restoreLayout() { newWindow(nil) }
        showPendingPreviews()
        startBridge()
        SelfCapture.scheduleIfRequested()
    }

    /// Closing the windows is not quitting: the red button hides the app and
    /// the panes keep running, so there is nothing to terminate after.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon, clicked while the app was hidden or had no window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.unhide(nil)
        if windows.isEmpty {
            newWindow(nil)
        } else {
            windows.last?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    @objc func newWindow(_ sender: Any?) {
        makeWindow(asTabOf: nil)
    }

    /// Cmd-T, and the + button macOS adds to the tab bar.
    @objc func newWindowForTab(_ sender: Any?) {
        makeWindow(asTabOf: currentController?.window)
    }

    /// Expands the folder sidebar of the front window, or collapses it.
    @objc func toggleFolderSidebar(_ sender: Any?) {
        currentController?.toggleSidebar()
    }

    /// Opens the sidebar on the Claude Code sessions of this machine.
    @objc func toggleSessionsSidebar(_ sender: Any?) {
        currentController?.toggleSessions()
    }

    @objc func splitHorizontally(_ sender: Any?) {
        currentController?.splitFocusedPane(vertical: true)
    }

    @objc func splitVertically(_ sender: Any?) {
        currentController?.splitFocusedPane(vertical: false)
    }

    /// Reads the configuration and starts following the file.
    ///
    /// A first run leaves a commented file behind: a configuration nobody can
    /// see is a configuration nobody edits.
    @MainActor
    private func loadConfiguration() {
        let (loaded, problems) = Config.load()
        config = loaded
        report(problems)

        if !FileManager.default.fileExists(atPath: Config.path.path) {
            try? FileManager.default.createDirectory(
                at: Config.path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? loaded.toml().write(to: Config.path, atomically: true, encoding: .utf8)
        }

        // The watcher fires on its own queue; the hop to main is where this
        // becomes safe to touch AppKit with.
        let watcher = ConfigWatcher { config, problems in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.configurationChanged(config, problems)
            }
        }
        watcher.start()
        configWatcher = watcher
    }

    @MainActor
    private func configurationChanged(_ config: Config, _ problems: [String]) {
        self.config = config
        report(problems)
        rebuildMenu()
        windows.forEach { $0.apply(config) }
        preferences.update(config: config)
    }

    private func rebuildMenu() {
        NSApp.mainMenu = MainMenu.build(keybindings: config.keybindings, bookmarks: bookmarks)
    }

    // MARK: - Folders

    /// `Cmd-P`: the quick switcher.
    @objc func showFolderPalette(_ sender: Any?) {
        guard !bookmarks.isEmpty else {
            // Nothing to switch to yet, so the manager is the useful answer.
            showFolders(sender)
            return
        }
        palette.show(bookmarks: bookmarks) { [weak self] bookmark in
            self?.openTab(for: bookmark)
        }
    }

    @objc func showFolders(_ sender: Any?) {
        foldersWindow.show(bookmarks: bookmarks) { [weak self] edited in
            self?.setBookmarks(edited)
        }
    }

    /// A folder opened once, without being kept.
    @objc func openFolderInNewTab(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openTab(for: Bookmark(name: url.lastPathComponent, path: url.path))
    }

    @objc func openBookmarkTab(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let bookmark = bookmarks.first(where: { $0.id.uuidString == identifier })
        else { return }
        openTab(for: bookmark)
    }

    /// Stars the directory the focused shell is actually in.
    ///
    /// Read from the process rather than remembered from when the tab opened: by
    /// the time this is used the user has usually `cd`'d somewhere, and that
    /// somewhere is what they mean.
    @objc func addCurrentFolder(_ sender: Any?) {
        guard let url = currentController?.focusedPane?.session.currentDirectory else {
            NSSound.beep()
            return
        }
        if let existing = bookmarks.first(where: { $0.url.path == url.path }) {
            // Already a favourite: show it rather than adding a duplicate the
            // user would then have to find and delete.
            showFolders(sender)
            foldersWindow.update(bookmarks: bookmarks)
            _ = existing
            return
        }
        setBookmarks(bookmarks + [Bookmark(name: url.lastPathComponent, path: url.path)])
        showFolders(sender)
    }

    private func setBookmarks(_ list: [Bookmark]) {
        bookmarks = list
        do {
            try bookmarkStore.save(list)
        } catch {
            FileHandle.standardError.write(Data("vitra: could not save folders: \(error)\n".utf8))
        }
        rebuildMenu()
        foldersWindow.update(bookmarks: list)
        windows.forEach { $0.refreshRail() }
    }

    /// Opens a folder as a tab of the front window, which is what a folder
    /// switcher is for: the windows stay together and the tab bar becomes the
    /// list of what is open.
    func openTab(for bookmark: Bookmark, running command: String? = nil, session: String? = nil) {
        // A remote favourite opens a local shell that immediately becomes an
        // ssh session; the working directory stays home, because the path in
        // the favourite belongs to the other machine.
        let command = command ?? bookmark.launchCommand
        makeWindow(asTabOf: currentController?.window, bookmark: bookmark, running: command, session: session)
    }

    private func report(_ problems: [String]) {
        for problem in problems {
            FileHandle.standardError.write(Data("vitra: \(problem)\n".utf8))
        }
    }

    @MainActor
    @objc func showPreferences(_ sender: Any?) {
        preferences.show(config: config) { [weak self] edited in
            // Saving writes the file; the watcher is what applies it, so there
            // is exactly one path from a setting to a window.
            try? edited.toml().write(to: Config.path, atomically: true, encoding: .utf8)
            self?.configurationChanged(edited, [])
        }
    }

    /// The sizes zooming will stop at, in points.
    private static let zoomLimits: ClosedRange<Double> = 8...32

    @MainActor
    @objc func zoomIn(_ sender: Any?) { zoom(to: config.fontSize + 1) }

    @MainActor
    @objc func zoomOut(_ sender: Any?) { zoom(to: config.fontSize - 1) }

    @MainActor
    @objc func actualSize(_ sender: Any?) { zoom(to: Config().fontSize) }

    /// Changes the font size everywhere, through the file like every other
    /// setting: a zoom that only lived in memory would be undone by the next
    /// save from the preferences window.
    @MainActor
    private func zoom(to size: Double) {
        let wanted = min(max(size, Self.zoomLimits.lowerBound), Self.zoomLimits.upperBound)
        guard wanted != config.fontSize else { return }
        var edited = config
        edited.fontSize = wanted
        try? edited.toml().write(to: Config.path, atomically: true, encoding: .utf8)
        configurationChanged(edited, [])
    }

    /// Serves MCP tool calls that `vitra mcp` forwards over the unix socket.
    @MainActor
    private func startBridge() {
        let server = MCPServer(executor: GUIToolExecutor(runner: ToolRunner(app: self)))
        let socket = SocketServer { request in await server.handle(request) }
        do {
            try socket.start()
            bridge = socket
        } catch {
            // Not fatal: a terminal that cannot serve tools is still a terminal.
            FileHandle.standardError.write(Data("vitra: bridge unavailable: \(error)\n".utf8))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveLayout()
        bridge?.stop()
    }

    // MARK: - Layout

    /// Writes down how the windows were arranged, so the next launch can open
    /// them again rather than making the user rebuild four panes by hand.
    private func saveLayout() {
        // A window opened on a command (`vitra -e ...`) is a one-off, and a
        // self-shot run is a measurement: neither is a workspace worth keeping,
        // unless the run brought its own layout file to write to.
        guard Self.commandFromArguments() == nil, Self.savesLayout else { return }

        // Tabs of one window share a tab group; separate windows do not. The
        // group is identified by position in the list so it survives the trip
        // through JSON.
        // Read once for every window: a pane's session is recognised by the
        // title it wears, and that needs the list of sessions on disk.
        let sessions = ClaudeSessionStore.recent().sessions
        var groups: [ObjectIdentifier: Int] = [:]
        var saved: [Layout.Window] = []
        for controller in windows {
            var group = groups.count
            if let tabGroup = controller.window?.tabGroup {
                let key = ObjectIdentifier(tabGroup)
                if let existing = groups[key] {
                    group = existing
                } else {
                    groups[key] = group
                }
            }
            guard let window = controller.layout(tabGroup: group, sessions: sessions) else { continue }
            saved.append(window)
        }

        guard !saved.isEmpty else {
            Layout.forget()
            return
        }
        try? Layout(windows: saved).save()
    }

    /// Opens the windows the last run left behind. False when there are none.
    @discardableResult
    private func restoreLayout() -> Bool {
        guard Self.commandFromArguments() == nil, Self.savesLayout, let layout = Layout.load()
        else { return false }

        var leaders: [Int: NSWindow] = [:]
        for saved in layout.windows {
            // A window with no folder of its own still has panes that had one;
            // without this the shell it opens starts at the root of the disk.
            let folder = saved.directory ?? saved.root.panes.compactMap(\.directory).first
            let bookmark = folder.map {
                Bookmark(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0)
            }
            makeWindow(asTabOf: leaders[saved.tabGroup], bookmark: bookmark, restoring: saved)
            guard let controller = windows.last, let window = controller.window else { continue }
            if leaders[saved.tabGroup] == nil { leaders[saved.tabGroup] = window }
            window.setFrame(
                NSRect(
                    x: saved.frame.x,
                    y: saved.frame.y,
                    width: saved.frame.width,
                    height: saved.frame.height
                ),
                display: false
            )
        }
        return !windows.isEmpty
    }

    @objc func togglePreviewPanel(_ sender: Any?) {
        currentController?.togglePanel()
    }

    /// Opens the browser in the side panel, with the address bar ready to type
    /// in: without this the browser is only reachable by clicking a link or by
    /// asking an agent, which is not a way to have a browser.
    @objc func openBrowser(_ sender: Any?) {
        currentController?.browser().focusAddress()
    }

    /// `vitra open <file>`, which reaches the running app as an open request.
    ///
    /// Files are previewed in the front window rather than opened as documents:
    /// Vitra is a terminal, and a file handed to it is something to look at.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingPreviews.append(contentsOf: urls)
        showPendingPreviews()
    }

    /// Opens whatever arrived before there was anywhere to show it.
    ///
    /// A file passed at launch reaches the delegate before
    /// applicationDidFinishLaunching, when there is no Metal device and so no
    /// window yet; without this the very first `vitra open` would be swallowed.
    private func showPendingPreviews() {
        guard device != nil, !pendingPreviews.isEmpty else { return }
        if currentController == nil { makeWindow(asTabOf: nil) }
        guard let controller = currentController else { return }

        let urls = pendingPreviews
        pendingPreviews.removeAll()
        for url in urls {
            guard let target = PreviewTarget.resolve(path: url.path) else { continue }
            controller.preview(target)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the window for real, ending what is running in it.
    ///
    /// The red button hides instead, so this menu item is the way to say
    /// "close" and mean it. Nothing asks for confirmation here for the same
    /// reason Close Pane does not: it is a deliberate command, not a stray
    /// click on a corner.
    @objc func closeWindow(_ sender: Any?) {
        currentController?.window?.close()
    }

    @objc func closePane(_ sender: Any?) {
        guard let controller = currentController else { return }
        controller.closeFocusedPane()
    }

    /// The window a command should act on.
    ///
    /// keyWindow is nil whenever the app is not frontmost, which would silently
    /// drop every menu action, so main and then most-recent are used as
    /// fallbacks.
    private var currentController: TerminalWindowController? {
        controller(for: NSApp.keyWindow)
            ?? controller(for: NSApp.mainWindow)
            ?? windows.last
    }

    private func makeWindow(
        asTabOf sibling: NSWindow?,
        bookmark: Bookmark? = nil,
        running: String? = nil,
        session: String? = nil,
        restoring: Layout.Window? = nil
    ) {
        guard let device else { return }
        do {
            let controller = try TerminalWindowController(
                device: device,
                fontName: config.fontName,
                fontSize: 13,
                command: Self.commandFromArguments(),
                attachments: attachments,
                config: config,
                bookmark: bookmark
            )
            windows.append(controller)

            if let sibling, let window = controller.window {
                sibling.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            } else {
                controller.showWindow(nil)
            }

            // After the window is on screen: the split proportions are shares of
            // a size, and a window that has not been laid out has none.
            if let restoring {
                controller.window?.layoutIfNeeded()
                controller.restore(restoring)
            }

            // The shell has to be up to read what it is handed: one hop, after
            // the window exists, rather than a timer waiting for a prompt.
            if let running {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    controller.run(running, session: session)
                }
            }
        } catch {
            fail("Could not open a terminal: \(error)")
        }
    }

    private func controller(for window: NSWindow?) -> TerminalWindowController? {
        windows.first { $0.window === window }
    }

    /// Drops controllers whose windows have closed, so sessions and their panes
    /// are released instead of accumulating for the life of the app.
    func windowWillClose(_ window: NSWindow) {
        windows.removeAll { $0.window === window }
    }

    /// `-e <command> [args...]` runs a command instead of the login shell, the
    /// same convention xterm established.
    /// Whether this run owns a workspace worth remembering.
    private static var savesLayout: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["VITRA_SELF_SHOT"] == nil || environment["VITRA_LAYOUT_PATH"] != nil
    }

    private static func commandFromArguments() -> [String]? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-e"), index + 1 < arguments.count else { return nil }
        return Array(arguments[(index + 1)...])
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Vitra"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

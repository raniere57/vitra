import AppKit
import Metal
import VitraBridge
import VitraCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var device: MTLDevice?
    private let attachments = AttachmentStore()

    /// Files handed to the app before it had a window to show them in.
    private var pendingPreviews: [URL] = []

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
        NSApp.mainMenu = MainMenu.build(keybindings: config.keybindings)
        if pendingPreviews.isEmpty { newWindow(nil) }
        showPendingPreviews()
        startBridge()
        SelfCapture.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        makeWindow(asTabOf: nil)
    }

    /// Cmd-T, and the + button macOS adds to the tab bar.
    @objc func newWindowForTab(_ sender: Any?) {
        makeWindow(asTabOf: currentController?.window)
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
        NSApp.mainMenu = MainMenu.build(keybindings: config.keybindings)
        windows.forEach { $0.apply(config) }
        preferences.update(config: config)
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
        bridge?.stop()
    }

    @objc func togglePreviewPanel(_ sender: Any?) {
        currentController?.togglePanel()
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

    private func makeWindow(asTabOf sibling: NSWindow?) {
        guard let device else { return }
        do {
            let controller = try TerminalWindowController(
                device: device,
                fontName: "Menlo",
                fontSize: 13,
                command: Self.commandFromArguments(),
                attachments: attachments,
                config: config
            )
            windows.append(controller)

            if let sibling, let window = controller.window {
                sibling.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            } else {
                controller.showWindow(nil)
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

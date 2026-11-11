import AppKit
import Metal
import VitraBridge
import VitraCore

/// The cockpit: Vitra as an orchestration tool, one tab per project.
///
/// It shares the terminal engine with the classic app and nothing of its
/// interface. `Vitra --classic` still opens the old one.
@MainActor
final class CockpitAppDelegate: NSObject, NSApplicationDelegate {
    private let feed = RunFeed()
    private var controller: CockpitWindowController?
    private var bridge: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One GUI, always. A `vitra mcp` helper that cannot reach the socket
        // launches the app; a second copy that came up while the first was
        // slow to answer would take the tools over with a window nobody is
        // looking at. A live socket owner means this process is the spare.
        // (A self-shot run is a measurement, not a rival, and quits itself.)
        if ProcessInfo.processInfo.environment["VITRA_SELF_SHOT"] == nil,
           SocketProbe.anotherInstanceIsServing() {
            NSApp.terminate(nil)
            return
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            let alert = NSAlert()
            alert.messageText = "O Vitra precisa de uma GPU com Metal."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let config = Config.load().config
        Harness.launchFlags[.claudeCode] = config.claudeFlags
        // Built from the one shortcut table the "Atalhos" sheet also reads.
        NSApp.mainMenu = Shortcut.makeMenuBar()

        // VITRA_COCKPIT_STORE points the tabs at another file, so an automated
        // run can open a fixture project without touching the user's own list.
        let store = ProcessInfo.processInfo.environment["VITRA_COCKPIT_STORE"].map(URL.init(fileURLWithPath:))
            ?? CockpitState.defaultURL
        let controller = CockpitWindowController(
            kit: TerminalKit(device: device, config: config),
            feed: feed,
            store: store
        )
        self.controller = controller
        // Not for an automated run: it is launched from a build folder, and
        // would point the user's CLIs at a binary that is about to be rebuilt.
        let environment = ProcessInfo.processInfo.environment
        if environment["VITRA_SELF_SHOT"] == nil, environment["VITRA_COCKPIT_STORE"] == nil,
           let binary = Bundle.main.executablePath {
            WorkerBrowser.register(binary: binary)
        }
        controller.showWindow(nil)
        feed.start()
        startBridge(host: controller)
        SelfCapture.scheduleIfRequested()
    }

    /// Serves the browser and preview tools to `vitra mcp` over the socket.
    private func startBridge(host: any ToolHost) {
        let server = MCPServer(executor: GUIToolExecutor(runner: ToolRunner(host: host)))
        let socket = SocketServer { request in await server.handle(request) }
        do {
            try socket.start()
            bridge = socket
        } catch {
            // Not fatal: the cockpit still orchestrates without a browser. The
            // agent that asks for one is told the app did not answer.
            FileHandle.standardError.write(Data("vitra: bridge unavailable: \(error)\n".utf8))
        }
    }

    private let quitHold = QuitHold()

    /// ⌘Q quits only when held; the menu item chosen with the pointer quits.
    @objc func quitRequested(_ sender: Any?) {
        quitHold.requested(in: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// Quitting leaves the project terminals running in the pty-host; this is
    /// the way to end them all, the host with them, and quit.
    @objc func endTerminalsAndQuit(_ sender: Any?) {
        controller?.endAllSessions()
        TerminalHosting.endAll { NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        feed.stop()
        bridge?.stop()
        controller?.shutDown()
    }
}

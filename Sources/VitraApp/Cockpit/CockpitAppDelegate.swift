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
        NSApp.mainMenu = makeMenu()

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        feed.stop()
        bridge?.stop()
        controller?.shutDown()
    }

    /// Only what the cockpit has: there is no item here that does nothing.
    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Sobre o Vitra", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Ocultar Vitra", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Encerrar Vitra", action: #selector(quitRequested(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "Arquivo")
        file.addItem(withTitle: "Abrir projeto…", action: #selector(CockpitWindowController.openProject(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Fechar projeto", action: #selector(CockpitWindowController.closeProject(_:)), keyEquivalent: "w")

        // Every tab is reachable without the pointer.
        let projects = NSMenu(title: "Projetos")
        let next = projects.addItem(withTitle: "Próximo projeto", action: #selector(CockpitWindowController.nextProject(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let previous = projects.addItem(withTitle: "Projeto anterior", action: #selector(CockpitWindowController.previousProject(_:)), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        projects.addItem(.separator())
        // The tabs of the right side: ⌃1 to ⌃5, beside ⌘1 to ⌘9 for projects.
        for (index, tab) in SideTab.allCases.enumerated() {
            let item = projects.addItem(withTitle: tab.title, action: #selector(CockpitWindowController.showSideTab(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.control]
            item.tag = index
        }
        projects.addItem(.separator())
        for number in 1...9 {
            let item = projects.addItem(withTitle: "Projeto \(number)", action: #selector(CockpitWindowController.showProject(_:)), keyEquivalent: "\(number)")
            item.tag = number - 1
        }

        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Limpar", action: #selector(TerminalView.clearScreen(_:)), keyEquivalent: "k")

        let window = NSMenu(title: "Janela")
        window.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        for menu in [app, file, projects, edit, window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }
}

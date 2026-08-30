import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var device: MTLDevice?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("Vitra needs a Metal-capable GPU.")
            return
        }
        self.device = device

        NSApp.mainMenu = MainMenu.build()
        newWindow(nil)
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
                command: Self.commandFromArguments()
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

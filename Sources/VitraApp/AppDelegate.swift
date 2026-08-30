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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        guard let device else { return }
        do {
            let controller = try TerminalWindowController(
                device: device,
                fontName: "Menlo",
                fontSize: 13,
                command: Self.commandFromArguments()
            )
            windows.append(controller)
            controller.showWindow(nil)
        } catch {
            fail("Could not open a terminal: \(error)")
        }
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

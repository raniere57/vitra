import AppKit
import Metal
import VitraCore
import VitraGhostty

/// One window holding one terminal.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let terminalView: TerminalView
    private let session: TerminalSession

    init(device: MTLDevice, fontName: String, fontSize: CGFloat, command: [String]? = nil) throws {
        let size = TerminalSize(columns: 80, rows: 24)
        let core = try GhosttyTerminalCore(size: size)
        session = try TerminalSession(
            core: core,
            executable: command?.first ?? ShellEnvironment.loginShell(),
            arguments: command.map { Array($0.dropFirst()) } ?? ["-l"],
            size: size
        )
        terminalView = try TerminalView(
            session: session,
            device: device,
            fontName: fontName,
            fontSize: fontSize
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 720, height: 460)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vitra"
        window.tabbingMode = .disallowed
        window.contentView = terminalView
        window.center()

        super.init(window: window)

        window.delegate = self
        window.makeFirstResponder(terminalView)

        session.onTitleChanged = { [weak window] title in
            window?.title = title.isEmpty ? "Vitra" : title
        }
        session.onBell = {
            NSSound.beep()
        }
        session.onExit = { [weak window] _ in
            // The shell exiting is the user closing the terminal.
            window?.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        // Size to a whole number of cells once the view knows its backing scale.
        if let window, let content = window.contentView {
            let ideal = terminalView.idealSize(columns: 80, rows: 24)
            if ideal != content.frame.size {
                window.setContentSize(ideal)
                window.center()
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        terminalView.updateBlinkTimer()
    }

    func windowDidResignKey(_ notification: Notification) {
        terminalView.updateBlinkTimer()
    }

    func windowWillClose(_ notification: Notification) {
        session.terminate()
    }
}

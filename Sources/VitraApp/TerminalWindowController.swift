import AppKit
import Metal
import VitraCore
import VitraGhostty

/// One window, holding a tree of split terminal panes.
///
/// The split tree is the view hierarchy itself: splitting a pane wraps it in an
/// `NSSplitView` in place. There is no parallel model to keep in sync, and
/// closing a pane collapses the tree by walking back up the same hierarchy.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let device: MTLDevice
    private let fontName: String
    private let fontSize: CGFloat
    private let command: [String]?

    /// Panes still alive in this window, in creation order.
    private var panes: [TerminalView] = []

    init(
        device: MTLDevice,
        fontName: String,
        fontSize: CGFloat,
        command: [String]? = nil
    ) throws {
        self.device = device
        self.fontName = fontName
        self.fontSize = fontSize
        self.command = command

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 720, height: 460)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vitra"
        // Native window tabbing: macOS supplies the tab bar, Cmd-Shift-[ and ],
        // drag-between-windows, and the + button, none of which is worth
        // reimplementing.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.vitra.terminal"
        window.center()

        super.init(window: window)

        let pane = try makePane()
        pane.frame = window.contentLayoutRect
        pane.autoresizingMask = [.width, .height]
        window.contentView = pane
        window.delegate = self
        window.makeFirstResponder(pane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)

        // Size to a whole number of cells, which is only knowable once the view
        // has a window and therefore a backing scale.
        if let window, let pane = panes.first, let content = window.contentView {
            let ideal = pane.idealSize(columns: 80, rows: 24)
            if ideal != content.frame.size {
                window.setContentSize(ideal)
                window.center()
            }
        }
    }

    // MARK: - Panes

    private func makePane() throws -> TerminalView {
        let size = TerminalSize(columns: 80, rows: 24)
        let core = try GhosttyTerminalCore(size: size)
        let session = try TerminalSession(
            core: core,
            executable: command?.first ?? ShellEnvironment.loginShell(),
            arguments: command.map { Array($0.dropFirst()) } ?? ["-l"],
            size: size
        )
        let pane = try TerminalView(
            session: session,
            device: device,
            fontName: fontName,
            fontSize: fontSize
        )

        session.onTitleChanged = { [weak self, weak pane] title in
            guard let pane, self?.focusedPane === pane else { return }
            self?.window?.title = title.isEmpty ? "Vitra" : title
        }
        session.onBell = { NSSound.beep() }
        session.onExit = { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.close(pane)
        }

        panes.append(pane)
        return pane
    }

    var focusedPane: TerminalView? {
        if let responder = window?.firstResponder as? TerminalView { return responder }
        return panes.last
    }

    /// Splits the focused pane, side by side or stacked.
    func splitFocusedPane(vertical: Bool) {
        guard let window, let pane = focusedPane else { return }

        // Where the pane sits has to be recorded before it is detached: removing
        // the content view clears window.contentView, so asking afterwards gives
        // the wrong answer.
        let wasContentView = window.contentView === pane
        let parentSplit = pane.superview as? NSSplitView
        let indexInParent = parentSplit?.arrangedSubviews.firstIndex(of: pane)
        guard wasContentView || (parentSplit != nil && indexInParent != nil) else { return }

        let newPane: TerminalView
        do {
            newPane = try makePane()
        } catch {
            NSSound.beep()
            return
        }

        let split = PaneSplitView()
        // isVertical means the divider runs vertically, which puts the panes
        // side by side.
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.frame = pane.frame
        split.autoresizingMask = [.width, .height]

        pane.removeFromSuperview()
        pane.autoresizingMask = [.width, .height]
        newPane.autoresizingMask = [.width, .height]
        split.addArrangedSubview(pane)
        split.addArrangedSubview(newPane)

        if let parentSplit, let indexInParent {
            parentSplit.insertArrangedSubview(split, at: indexInParent)
            parentSplit.adjustSubviews()
        } else {
            window.contentView = split
        }

        // adjustSubviews() divides the space in proportion to what the subviews
        // already have, and the new pane starts at zero width, so it would stay
        // at zero. Placing the divider explicitly is what actually splits it.
        split.adjustSubviews()
        split.setPosition(
            (vertical ? split.bounds.width : split.bounds.height) / 2,
            ofDividerAt: 0
        )
        window.makeFirstResponder(newPane)
    }

    /// Removes a pane and collapses any split that is left with a single child.
    func close(_ pane: TerminalView) {
        panes.removeAll { $0 === pane }
        pane.prepareForRemoval()

        guard let window, let split = pane.superview as? NSSplitView else {
            // Last pane in the window: the window goes with it.
            window?.close()
            return
        }

        // Same ordering care as splitting: read the position first, detach after.
        let splitWasContentView = window.contentView === split
        let parentSplit = split.superview as? NSSplitView
        let indexInParent = parentSplit?.arrangedSubviews.firstIndex(of: split)
        let frame = split.frame

        pane.removeFromSuperview()
        guard let survivor = split.arrangedSubviews.first else { return }

        // A split with one child left is just that child.
        survivor.removeFromSuperview()
        survivor.frame = frame
        survivor.autoresizingMask = [.width, .height]
        split.removeFromSuperview()

        if let parentSplit, let indexInParent {
            parentSplit.insertArrangedSubview(survivor, at: indexInParent)
            parentSplit.adjustSubviews()
        } else if splitWasContentView {
            window.contentView = survivor
        }

        window.makeFirstResponder(panes.first { $0.window != nil })
    }

    func closeFocusedPane() {
        guard let pane = focusedPane else { return }
        pane.session.terminate()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        panes.forEach { $0.updateBlinkTimer() }
    }

    func windowDidResignKey(_ notification: Notification) {
        panes.forEach { $0.updateBlinkTimer() }
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.prepareForRemoval() }
        panes.forEach { $0.session.terminate() }
        panes.removeAll()
    }
}


/// A split view whose divider is visible against a dark terminal.
///
/// The stock divider colour is chosen for light content and vanishes entirely on
/// a black background, leaving no way to see or grab the split.
private final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { NSColor(white: 0.22, alpha: 1) }
    override var dividerThickness: CGFloat { 1 }
}

import AppKit
import Metal
import VitraCore
import VitraGhostty
import VitraPanel

/// One window, holding a tree of split terminal panes.
///
/// The split tree is the view hierarchy itself: splitting a pane wraps it in an
/// `NSSplitView` in place. There is no parallel model to keep in sync, and
/// closing a pane collapses the tree by walking back up the same hierarchy.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    private let device: MTLDevice
    private let fontName: String
    private let fontSize: CGFloat
    private let command: [String]?
    private let attachments: AttachmentStore

    /// Panes still alive in this window, in creation order.
    private var panes: [TerminalView] = []

    /// Holds the split tree of panes. Everything about splitting happens inside
    /// this view, so opening the preview panel never disturbs the pane
    /// hierarchy — the panel is added beside the container, not around a pane.
    private let paneContainer = NSView()

    /// Built the first time the panel is opened, and kept afterwards.
    private var panel: PreviewPanel?
    private var panelSplit: NSSplitView?

    init(
        device: MTLDevice,
        fontName: String,
        fontSize: CGFloat,
        command: [String]? = nil,
        attachments: AttachmentStore = AttachmentStore()
    ) throws {
        self.device = device
        self.fontName = fontName
        self.fontSize = fontSize
        self.command = command
        self.attachments = attachments

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
        paneContainer.frame = window.contentLayoutRect
        paneContainer.autoresizingMask = [.width, .height]
        pane.frame = paneContainer.bounds
        pane.autoresizingMask = [.width, .height]
        paneContainer.addSubview(pane)
        window.contentView = paneContainer
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
        if let window, let pane = panes.first {
            let ideal = pane.idealSize(columns: 80, rows: 24)
            if ideal != paneContainer.frame.size {
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
            fontSize: fontSize,
            attachments: attachments
        )

        session.onTitleChanged = { [weak self, weak pane] title in
            guard let pane, self?.focusedPane === pane else { return }
            self?.window?.title = title.isEmpty ? "Vitra" : title
        }
        session.onBell = { NSSound.beep() }
        session.onPreviewRequest = { [weak self] target in
            // Arrives on the session's read queue; the panel is main-thread only.
            DispatchQueue.main.async { self?.preview(target) }
        }
        session.onExit = { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.close(pane)
        }

        panes.append(pane)
        // Only now, with every callback installed, is it safe to let output in.
        session.start()
        return pane
    }

    var focusedPane: TerminalView? {
        if let responder = window?.firstResponder as? TerminalView { return responder }
        return panes.last
    }

    /// Splits the focused pane, side by side or stacked.
    func splitFocusedPane(vertical: Bool) {
        guard let window, let pane = focusedPane else { return }

        // Where the pane sits has to be recorded before it is detached:
        // removing it from the container clears the relationship, so asking
        // afterwards gives the wrong answer.
        let wasRoot = pane.superview === paneContainer
        let parentSplit = pane.superview as? NSSplitView
        let indexInParent = parentSplit?.arrangedSubviews.firstIndex(of: pane)
        guard wasRoot || (parentSplit != nil && indexInParent != nil) else { return }

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
            split.frame = paneContainer.bounds
            paneContainer.addSubview(split)
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
        let splitWasRoot = split.superview === paneContainer
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
        } else if splitWasRoot {
            survivor.frame = paneContainer.bounds
            paneContainer.addSubview(survivor)
        }

        window.makeFirstResponder(panes.first { $0.window != nil })
    }

    // MARK: - Preview panel

    /// Shows a file in the side panel, opening the panel if it is closed.
    func preview(_ target: PreviewTarget) {
        openPanel().show(target)
    }

    /// The browser in the side panel, opening the panel if it is closed.
    func browser() -> BrowserView {
        openPanel().browser()
    }

    /// `Cmd-Shift-P`: opens the panel, or closes it and releases its contents.
    func togglePanel() {
        if panel == nil { _ = openPanel() } else { closePanel() }
    }

    @discardableResult
    private func openPanel() -> PreviewPanel {
        if let panel { return panel }

        let panel = PreviewPanel(frame: .zero)
        panel.onClose = { [weak self] in self?.closePanel() }

        let split = PaneSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.frame = window?.contentLayoutRect ?? paneContainer.frame
        split.autoresizingMask = [.width, .height]

        paneContainer.removeFromSuperview()
        split.addArrangedSubview(paneContainer)
        split.addArrangedSubview(panel)
        split.delegate = self
        window?.contentView = split

        // After layout: the split has no width of its own until the window has
        // sized it, and a divider placed before that collapses the terminal.
        split.layoutSubtreeIfNeeded()
        let width = split.bounds.width
        split.setPosition(max(width / 2, width - PanelStyle.defaultWidth), ofDividerAt: 0)

        self.panel = panel
        self.panelSplit = split
        return panel
    }

    private func closePanel() {
        guard let panel, let split = panelSplit else { return }
        // Releasing the content is the point: a web preview holds a WebKit
        // content process open until its view is dropped.
        panel.clearContent()
        panel.removeFromSuperview()

        paneContainer.removeFromSuperview()
        paneContainer.frame = split.frame
        paneContainer.autoresizingMask = [.width, .height]
        split.removeFromSuperview()
        window?.contentView = paneContainer

        self.panel = nil
        self.panelSplit = nil
        window?.makeFirstResponder(focusedPane)
    }

    func closeFocusedPane() {
        guard let pane = focusedPane else { return }
        pane.session.terminate()
    }

    // MARK: - NSSplitViewDelegate

    /// The terminal keeps a usable width; the panel keeps a readable one.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, 240)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, splitView.bounds.width - PanelStyle.minimumWidth)
    }

    /// Growing the window gives the extra width to the terminal, which is what a
    /// side panel is expected to do.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== panel
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


/// A split view whose divider is visible against a dark terminal, and whose
/// panes keep their proportions when it is resized.
///
/// The stock divider colour is chosen for light content and vanishes entirely on
/// a black background, leaving no way to see or grab the split. And the stock
/// resize takes the whole difference out of the first pane, which turns a 50/50
/// split into a sliver the moment the preview panel opens beside it.
private final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var dividerColor: NSColor { NSColor(white: 0.22, alpha: 1) }
    override var dividerThickness: CGFloat { 1 }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let views = splitView.arrangedSubviews
        guard views.count > 1 else {
            splitView.adjustSubviews()
            return
        }

        let vertical = splitView.isVertical
        let dividers = splitView.dividerThickness * CGFloat(views.count - 1)
        let oldAvailable = (vertical ? oldSize.width : oldSize.height) - dividers
        let newAvailable = (vertical ? splitView.bounds.width : splitView.bounds.height) - dividers
        guard oldAvailable > 0, newAvailable > 0 else {
            splitView.adjustSubviews()
            return
        }

        let scale = newAvailable / oldAvailable
        let across = vertical ? splitView.bounds.height : splitView.bounds.width
        var offset: CGFloat = 0

        for (index, view) in views.enumerated() {
            let isLast = index == views.count - 1
            let current = vertical ? view.frame.width : view.frame.height
            // The last pane absorbs the rounding, so the panes always add up.
            let length = isLast ? newAvailable + dividers - offset : (current * scale).rounded()
            view.frame = vertical
                ? NSRect(x: offset, y: 0, width: length, height: across)
                : NSRect(x: 0, y: offset, width: across, height: length)
            offset += length + splitView.dividerThickness
        }
    }
}

import Darwin
import Foundation

/// One terminal: a pty, an emulator, and the queue that serializes them.
///
/// libghostty requires serialized access to the terminal, so every read, write,
/// resize, and snapshot goes through `queue`. Callers on the main thread use the
/// public API and never touch the core directly.
public final class TerminalSession: @unchecked Sendable {
    public let core: TerminalCore
    public private(set) var size: TerminalSize

    /// Called on the main queue when the screen has changed and needs redrawing.
    ///
    /// Coalesced: it fires at most once per redraw, no matter how much output
    /// arrives in between, so a firehose of output cannot flood the main thread.
    public var onNeedsRedraw: (@Sendable () -> Void)?
    public var onTitleChanged: (@Sendable (String) -> Void)?
    public var onBell: (@Sendable () -> Void)?
    public var onExit: (@Sendable (Int32?) -> Void)?

    private let pty: PTY
    private let queue: DispatchQueue
    private var redrawPending = false
    private var hasExited = false
    private var selectionAnchor: GridPosition?
    private var selectionMode: SelectionMode = .cell

    public init(
        core: TerminalCore,
        executable: String = ShellEnvironment.loginShell(),
        arguments: [String] = ["-l"],
        environment: [String: String] = ShellEnvironment.childEnvironment(),
        size: TerminalSize
    ) throws {
        self.core = core
        self.size = size
        self.queue = DispatchQueue(label: "dev.vitra.session", qos: .userInteractive)
        self.pty = try PTY(
            executable: executable,
            arguments: arguments,
            environment: environment,
            size: size
        )

        core.onWritePTY = { [pty] bytes in
            // Query responses; the terminal is answering a program's probe.
            try? pty.write(bytes)
        }
        core.onTitleChanged = { [weak self] title in
            guard let handler = self?.onTitleChanged else { return }
            DispatchQueue.main.async { handler(title) }
        }
        core.onBell = { [weak self] in
            guard let handler = self?.onBell else { return }
            DispatchQueue.main.async { handler() }
        }

        pty.startReading(
            on: queue,
            onData: { [weak self] bytes in
                self?.core.feed(bytes)
                self?.scheduleRedraw()
            },
            onEOF: { [weak self] in
                self?.handleExit()
            }
        )
    }

    deinit {
        pty.close()
    }

    // MARK: - Input

    public func send(_ event: KeyEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            let bytes = self.core.encode(event)
            guard !bytes.isEmpty else { return }
            bytes.withUnsafeBytes { try? self.pty.write($0) }
        }
    }

    /// Writes text to the child as if typed, without going through key encoding.
    public func send(text: String) {
        queue.async { [weak self] in
            try? self?.pty.write(text)
        }
    }

    /// Scrolls the viewport by `lines`; negative scrolls up into scrollback.
    public func scroll(lines: Int) {
        guard lines != 0 else { return }
        queue.async { [weak self] in
            self?.core.scrollViewport(lines: lines)
            self?.scheduleRedraw()
        }
    }

    public func scrollToBottom() {
        queue.async { [weak self] in
            self?.core.scrollToBottom()
            self?.scheduleRedraw()
        }
    }

    /// Clears the screen and scrollback without disturbing the running program.
    ///
    /// The sequences are fed to the emulator rather than written to the pty: the
    /// shell should not see them, and would echo them if it did.
    public func clearScreen() {
        queue.async { [weak self] in
            self?.core.feed("\u{1B}[H\u{1B}[2J\u{1B}[3J")
            self?.scheduleRedraw()
        }
    }

    // MARK: - Selection

    /// Starts a selection at a viewport cell. `clickCount` picks cell, word, or
    /// line granularity.
    public func beginSelection(column: UInt16, row: UInt16, clickCount: Int) {
        queue.async { [weak self] in
            guard let self, let anchor = self.core.screenPosition(viewportColumn: column, viewportRow: row)
            else { return }
            self.selectionAnchor = anchor
            self.selectionMode = SelectionMode(clickCount: clickCount)

            // A double or triple click selects immediately, without waiting for a
            // drag; a single click just places the anchor and clears any old
            // selection.
            if self.selectionMode == .cell {
                self.core.clearSelection()
            } else {
                self.core.setSelection(from: anchor, to: anchor, mode: self.selectionMode, rectangle: false)
            }
            self.scheduleRedraw()
        }
    }

    public func extendSelection(column: UInt16, row: UInt16, rectangle: Bool = false) {
        queue.async { [weak self] in
            guard let self,
                  let anchor = self.selectionAnchor,
                  let position = self.core.screenPosition(viewportColumn: column, viewportRow: row)
            else { return }
            self.core.setSelection(from: anchor, to: position, mode: self.selectionMode, rectangle: rectangle)
            self.scheduleRedraw()
        }
    }

    public func endSelection() {
        queue.async { [weak self] in self?.selectionAnchor = nil }
    }

    public func selectAll() {
        queue.async { [weak self] in
            self?.core.selectAll()
            self?.scheduleRedraw()
        }
    }

    public func clearSelection() {
        queue.async { [weak self] in
            self?.selectionAnchor = nil
            self?.core.clearSelection()
            self?.scheduleRedraw()
        }
    }

    /// The selected text, read synchronously because the clipboard needs it now.
    public func selectedText() -> String? {
        queue.sync { core.selectedText() }
    }

    /// Sends text as a paste, wrapped in bracketed paste when the program asked
    /// for it.
    public func paste(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let bytes = self.core.encodePaste(text)
            guard !bytes.isEmpty else { return }
            bytes.withUnsafeBytes { try? self.pty.write($0) }
        }
    }

    // MARK: - Geometry

    public func resize(to size: TerminalSize) {
        queue.async { [weak self] in
            guard let self, self.size != size else { return }
            self.size = size
            try? self.core.resize(to: size)
            // The kernel delivers SIGWINCH from this, which is how the child
            // learns to redraw itself.
            self.pty.resize(to: size)
            self.scheduleRedraw()
        }
    }

    // MARK: - Rendering

    /// Refills `snapshot` from the terminal, returning false if nothing changed.
    ///
    /// ponytail: synchronous hop onto the session queue. Output is processed in
    /// 64 KB chunks so the wait is short; double-buffer the snapshot if a profile
    /// ever shows the main thread waiting here.
    public func updateSnapshot(_ snapshot: RenderSnapshot) -> Bool {
        queue.sync {
            redrawPending = false
            return (try? core.updateSnapshot(snapshot)) ?? false
        }
    }

    /// Marks the screen as needing a redraw, at most once per frame.
    private func scheduleRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        guard let handler = onNeedsRedraw else { return }
        DispatchQueue.main.async { handler() }
    }

    // MARK: - Lifecycle

    public func terminate() {
        pty.terminate()
    }

    private func handleExit() {
        guard !hasExited else { return }
        hasExited = true
        let status = pty.reap(blocking: true)
        // The child's last output arrives before EOF, so there is always a final
        // frame worth drawing.
        redrawPending = false
        let redraw = onNeedsRedraw
        let exit = onExit
        DispatchQueue.main.async {
            redraw?()
            exit?(status)
        }
    }
}

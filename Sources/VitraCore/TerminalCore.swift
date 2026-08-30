import Foundation

/// The terminal emulation engine, behind a boundary that hides which engine it is.
///
/// Everything above this protocol (the renderer, the app) is written against
/// `TerminalCore` and never against libghostty directly. That boundary is what
/// makes swapping the engine a contained change rather than a rewrite.
public protocol TerminalCore: AnyObject {
    var size: TerminalSize { get }

    /// Bytes the emulator wants written back to the pty: device status reports,
    /// device attributes, cursor position queries. Programs that probe the
    /// terminal hang forever when these go unanswered.
    var onWritePTY: (@Sendable (UnsafeRawBufferPointer) -> Void)? { get set }
    var onTitleChanged: (@Sendable (String) -> Void)? { get set }
    var onBell: (@Sendable () -> Void)? { get set }

    /// Feeds bytes read from the PTY into the emulator.
    func feed(_ bytes: UnsafeRawBufferPointer)

    /// Resizes the screen, reflowing existing content.
    func resize(to size: TerminalSize) throws

    /// Whether the program running inside asked for bracketed paste (mode 2004).
    ///
    /// Pasting without honouring this lets pasted newlines run as commands, so
    /// it is a safety property, not a formatting preference.
    var isBracketedPasteEnabled: Bool { get }

    /// Converts a viewport cell coordinate into a scrollback-absolute position.
    func screenPosition(viewportColumn: UInt16, viewportRow: UInt16) -> GridPosition?

    /// Selects between two screen positions. `mode` widens the range to whole
    /// words or lines, matching double- and triple-click behaviour.
    func setSelection(from: GridPosition, to: GridPosition, mode: SelectionMode, rectangle: Bool)

    func selectAll()
    func clearSelection()

    /// The currently selected text, or nil when there is no selection.
    func selectedText() -> String?

    /// Encodes text for the pty as a paste, stripping control bytes and applying
    /// bracketed paste when the running program enabled it.
    func encodePaste(_ text: String) -> [UInt8]

    /// Scrolls the viewport by `lines`; negative scrolls up into scrollback.
    func scrollViewport(lines: Int)

    /// Scrolls the viewport back to the live edge of the screen.
    func scrollToBottom()

    /// Encodes a key event into the bytes to write to the pty.
    ///
    /// Encoding depends on live terminal state (application cursor keys, the
    /// Kitty keyboard protocol flags, modifyOtherKeys), which is why it belongs
    /// to the engine rather than to the view that captured the keystroke.
    func encode(_ event: KeyEvent) -> [UInt8]

    /// Refills `snapshot` with the current grid, or returns false if nothing has
    /// changed since the last call and the previous frame is still valid.
    ///
    /// This is what keeps the renderer off the CPU when the screen is static.
    func updateSnapshot(_ snapshot: RenderSnapshot) throws -> Bool

    /// The active screen as plain text, including scrollback, trailing blanks trimmed.
    ///
    /// This is a diagnostic and testing surface, not the rendering path — the
    /// renderer reads cell state directly. It exists so terminal behaviour can be
    /// asserted without a window. Note this is the whole screen and not just the
    /// visible viewport, so scrolled-off lines still appear.
    func screenText() -> String
}

public extension TerminalCore {
    func feed(_ data: Data) {
        data.withUnsafeBytes { feed($0) }
    }

    func feed(_ string: String) {
        var copy = string
        copy.withUTF8 { feed(UnsafeRawBufferPointer($0)) }
    }
}

public enum TerminalCoreError: Error, CustomStringConvertible {
    case allocationFailed
    case operationFailed(String, code: Int32)

    public var description: String {
        switch self {
        case .allocationFailed:
            return "terminal core allocation failed"
        case let .operationFailed(what, code):
            return "terminal core \(what) failed (code \(code))"
        }
    }
}

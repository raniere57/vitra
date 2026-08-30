import Foundation

/// The terminal emulation engine, behind a boundary that hides which engine it is.
///
/// Everything above this protocol (the renderer, the app) is written against
/// `TerminalCore` and never against libghostty directly. That boundary is what
/// makes swapping the engine a contained change rather than a rewrite.
public protocol TerminalCore: AnyObject {
    var size: TerminalSize { get }

    /// Feeds bytes read from the PTY into the emulator.
    func feed(_ bytes: UnsafeRawBufferPointer)

    /// Resizes the screen, reflowing existing content.
    func resize(to size: TerminalSize) throws

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

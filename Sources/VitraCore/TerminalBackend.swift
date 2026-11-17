import Darwin
import Foundation

/// Where a terminal's child lives and how its bytes get to and fro.
///
/// Two kinds: `PTY`, the child in this process's own pty, and `HostedPTY`,
/// the child in `Vitra pty-host`, which outlives the app. `TerminalSession`
/// drives either the same way, on its own queue.
public protocol TerminalBackend: AnyObject, Sendable {
    /// Delivers output on `queue` until the child exits, then `onEOF` once.
    func startReading(
        on queue: DispatchQueue,
        onData: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onEOF: @escaping @Sendable () -> Void
    )
    func write(_ bytes: UnsafeRawBufferPointer) throws
    func resize(to size: TerminalSize)

    var workingDirectory: URL? { get }
    var foregroundName: String? { get }
    var hasForegroundJob: Bool { get }

    /// True, on the session's queue, while the bytes being delivered are a
    /// replay of earlier output: the terminal must draw them but must not
    /// answer the queries in them, nor act on the requests.
    var isReplaying: Bool { get }

    /// Ends the child.
    func terminate()
    /// Lets go of the child without ending it, where it can outlive us.
    func detach()
    func reap(blocking: Bool) -> Int32?
    func close()
}

public extension TerminalBackend {
    func write(_ string: String) throws {
        var copy = string
        try copy.withUTF8 { try write(UnsafeRawBufferPointer($0)) }
    }
}

extension PTY: TerminalBackend {
    public var isReplaying: Bool { false }

    /// A child in our own pty cannot outlive us: letting go is ending it.
    public func detach() { terminate() }
}

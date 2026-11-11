import Foundation

/// The wire format between the app and `Vitra pty-host`.
///
/// The host outlives the app, and the app is reinstalled several times a day,
/// so a newer app routinely talks to an older host. The protocol is kept tiny
/// for that reason: one connection per terminal, a version said once in
/// `hello`, JSON for the few control messages (unknown fields are ignored,
/// so adding one is not a break) and raw bytes for the terminal's traffic.
///
/// A frame is four bytes of big-endian length, one byte of kind, then the body.
public enum PTYHostProtocol {
    /// Bumped only for a change an older peer would misread. Both sides say
    /// theirs in `hello`; the app falls back to an in-process terminal when
    /// they differ rather than guess.
    public static let version = 1

    /// A frame larger than this is a wrong-protocol peer, not a terminal.
    static let maximumFrame = 4 * 1024 * 1024

    /// Output is sent in pieces no larger than this, the replay included.
    static let chunk = 64 * 1024

    enum Kind: UInt8 {
        /// A `PTYHostMessage` as JSON.
        case control = 1
        /// The child's output, live.
        case output = 2
        /// The child's earlier output, sent on attach to redraw the screen.
        /// Kept apart from `output` because the terminal must not answer the
        /// queries in it: they were asked of a terminal that is gone.
        case replay = 3
        /// What the user typed, for the child.
        case input = 4
    }

    static func frame(_ kind: Kind, _ body: Data) -> Data {
        var length = UInt32(body.count + 1).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(kind.rawValue)
        out.append(body)
        return out
    }

    static func frame(_ message: PTYHostMessage) -> Data {
        // Encoding a struct of strings and numbers cannot fail.
        frame(.control, (try? JSONEncoder().encode(message)) ?? Data())
    }

    /// Pulls one complete frame off the front of `buffer`, if there is one.
    /// A frame of an unknown kind comes back as nil kind, to be skipped: a
    /// newer peer may send one.
    static func nextFrame(from buffer: inout Data) throws -> (kind: Kind?, body: Data)? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length >= 1, length <= maximumFrame else { throw PTYHostError.badFrame(length) }
        guard buffer.count >= 4 + length else { return nil }
        let kind = Kind(rawValue: buffer[start + 4])
        let body = Data(buffer[(start + 5)..<(start + 4 + length)])
        buffer.removeSubrange(start..<(start + 4 + length))
        return (kind, body)
    }

    /// Whether an app at `version` can use a host that says `hostVersion`.
    public static func isCompatible(hostVersion: Int?) -> Bool {
        hostVersion == version
    }
}

/// One control message, either way. Flat, with every field optional, so each
/// side reads what it knows and ignores the rest.
///
/// From the app: `hello`, `open` (attach to a live session with this id, or
/// start one), `attach` (only if it exists), `resize`, `close`, `list`,
/// `shutdown`. From the host: `hello`, `attached`, `exited`, `list`, `ok`,
/// `error`.
public struct PTYHostMessage: Codable, Equatable, Sendable {
    public var op: String
    public var version: Int?
    public var id: String?
    public var cwd: String?
    public var env: [String: String]?
    public var argv: [String]?
    public var cols: Int?
    public var rows: Int?
    public var pid: Int32?
    /// On `attached`: whether a new child was started for this connection.
    public var created: Bool?
    public var status: Int32?
    public var message: String?
    public var sessions: [PTYHostSessionInfo]?

    public init(
        op: String, version: Int? = nil, id: String? = nil, cwd: String? = nil,
        env: [String: String]? = nil, argv: [String]? = nil, cols: Int? = nil, rows: Int? = nil,
        pid: Int32? = nil, created: Bool? = nil, status: Int32? = nil, message: String? = nil,
        sessions: [PTYHostSessionInfo]? = nil
    ) {
        self.op = op
        self.version = version
        self.id = id
        self.cwd = cwd
        self.env = env
        self.argv = argv
        self.cols = cols
        self.rows = rows
        self.pid = pid
        self.created = created
        self.status = status
        self.message = message
        self.sessions = sessions
    }
}

/// A session as `list` describes it.
public struct PTYHostSessionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var cwd: String
    public var pid: Int32
    public var alive: Bool
    public var started: Date
}

public enum PTYHostError: Error, CustomStringConvertible {
    case badFrame(Int)
    case unreachable(String)
    case refused(String)
    case incompatible(Int?)

    public var description: String {
        switch self {
        case let .badFrame(length): return "pty-host frame of \(length) bytes is not valid"
        case let .unreachable(why): return "pty-host unreachable: \(why)"
        case let .refused(why): return "pty-host refused: \(why)"
        case let .incompatible(version): return "pty-host speaks version \(version.map(String.init) ?? "?"), not \(PTYHostProtocol.version)"
        }
    }
}

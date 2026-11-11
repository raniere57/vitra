import Darwin
import Foundation

/// Where the host keeps its socket and its lock.
///
/// A folder of its own, mode 0700, rather than files loose in `~/.vitra`:
/// that folder is 0755 on existing installs, and a terminal's socket — which
/// takes keystrokes for a shell — belongs somewhere nobody else can even list.
public struct PTYHostPaths: Sendable {
    public let directory: URL
    public var socket: String { directory.appendingPathComponent("host.sock").path }
    public var lock: String { directory.appendingPathComponent("host.lock").path }

    public init(directory: URL) { self.directory = directory }

    public static let standard = PTYHostPaths(directory: Vitra.supportDirectory.appendingPathComponent("pty-host", isDirectory: true))

    /// Creates the folder if needed and tightens it to 0700 either way.
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
    }
}

/// The few socket calls both ends need, blocking and short.
enum PTYHostSocket {
    /// Only the user who owns the host may drive its shells.
    static func admits(peer: uid_t?, own: uid_t = getuid()) -> Bool {
        peer == own
    }

    static func peerUID(of fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    static func listen(at path: String) throws -> Int32 {
        let fd = try makeSocket()
        var address = try makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw PTYHostError.unreachable("bind \(path): \(String(cString: strerror(failure)))")
        }
        chmod(path, 0o600)
        return fd
    }

    /// A connected socket, or a throw when nothing is listening at `path`.
    /// `timeout` bounds every later blocking read and write on it.
    static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = try makeSocket()
        var address = try makeAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw PTYHostError.unreachable("connect: \(String(cString: strerror(failure)))")
        }
        setTimeout(fd, timeout)
        return fd
    }

    /// Bounds blocking reads and writes; zero means no bound.
    static func setTimeout(_ fd: Int32, _ timeout: TimeInterval) {
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes all of `data`; false when the peer is gone or stopped reading.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Reads into `buffer` until it holds a whole frame, and returns it.
    /// Blocking, bounded by the socket's timeout.
    static func readFrame(_ fd: Int32, buffer: inout Data) throws -> (kind: PTYHostProtocol.Kind?, body: Data) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let frame = try PTYHostProtocol.nextFrame(from: &buffer) { return frame }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n < 0, errno == EINTR { continue }
            throw PTYHostError.unreachable(n == 0 ? "closed" : "read: \(String(cString: strerror(errno)))")
        }
    }

    /// Reads control frames until one arrives, skipping anything else.
    static func readMessage(_ fd: Int32, buffer: inout Data) throws -> PTYHostMessage {
        while true {
            let frame = try readFrame(fd, buffer: &buffer)
            guard frame.kind == .control else { continue }
            guard let message = try? JSONDecoder().decode(PTYHostMessage.self, from: frame.body) else {
                throw PTYHostError.refused("unreadable reply")
            }
            return message
        }
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PTYHostError.unreachable("socket: \(String(cString: strerror(errno)))") }
        // A peer that went away must be an error return, never a SIGPIPE that
        // kills the app or the host.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw PTYHostError.unreachable("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return address
    }
}

import Darwin
import Foundation

/// The app's side of the host, for everything but a terminal's own stream:
/// reaching the host (starting it if needed) and one-shot requests.
///
/// Every call blocks, bounded by a timeout, and none may run on the main
/// thread.
public enum PTYHostClient {
    /// How long the app waits for a host before it gives up on it and keeps
    /// the terminal in-process.
    public static let patience: TimeInterval = 2

    /// A connection to the host that has said a compatible hello, with any
    /// bytes read past that reply. When nothing answers and `binary` is
    /// given, a host is started from it and waited for until `deadline`.
    static func connect(paths: PTYHostPaths, launching binary: String?, deadline: Date) throws -> (fd: Int32, buffer: Data) {
        do {
            return try handshake(paths: paths, deadline: deadline)
        } catch let error as PTYHostError {
            guard case .unreachable = error, binary != nil else { throw error }
        }
        if let binary { try launch(binary: binary) }
        while true {
            do {
                return try handshake(paths: paths, deadline: deadline)
            } catch let error as PTYHostError {
                guard case .unreachable = error, Date() < deadline else { throw error }
            }
            usleep(50_000)
        }
    }

    /// Connects and trades hellos. Throws `.incompatible` when the host
    /// speaks another version; the connection is closed then.
    static func handshake(paths: PTYHostPaths, deadline: Date, requireCompatible: Bool = true) throws -> (fd: Int32, buffer: Data) {
        let fd = try PTYHostSocket.connect(to: paths.socket, timeout: max(deadline.timeIntervalSinceNow, 0.1))
        var buffer = Data()
        do {
            guard PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(PTYHostMessage(op: "hello", version: PTYHostProtocol.version))) else {
                throw PTYHostError.unreachable("hello not sent")
            }
            let reply = try PTYHostSocket.readMessage(fd, buffer: &buffer)
            if requireCompatible, !PTYHostProtocol.isCompatible(hostVersion: reply.version) {
                throw PTYHostError.incompatible(reply.version)
            }
            return (fd, buffer)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// One request, one reply, on a connection of its own.
    @discardableResult
    public static func request(
        _ message: PTYHostMessage,
        paths: PTYHostPaths = .standard,
        timeout: TimeInterval = patience,
        requireCompatible: Bool = true
    ) throws -> PTYHostMessage {
        var (fd, buffer) = try handshake(paths: paths, deadline: Date() + timeout, requireCompatible: requireCompatible)
        defer { Darwin.close(fd) }
        guard PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(message)) else { throw PTYHostError.unreachable("request not sent") }
        let reply = try PTYHostSocket.readMessage(fd, buffer: &buffer)
        if reply.op == "error" { throw PTYHostError.refused(reply.message ?? "error") }
        return reply
    }

    public static func list(paths: PTYHostPaths = .standard) throws -> [PTYHostSessionInfo] {
        try request(PTYHostMessage(op: "list"), paths: paths).sessions ?? []
    }

    /// Ends one session: its child is hung up on and reaped.
    public static func close(id: String, paths: PTYHostPaths = .standard) throws {
        try request(PTYHostMessage(op: "close", id: id), paths: paths)
    }

    /// Ends every session and the host. Sent whatever version the host
    /// speaks: `shutdown` means the same to all of them, and an old host left
    /// behind by an upgrade is exactly the one worth stopping.
    public static func shutdown(paths: PTYHostPaths = .standard) throws {
        try request(PTYHostMessage(op: "shutdown"), paths: paths, requireCompatible: false)
    }

    /// Starts `binary pty-host` detached from the app: its own session, no
    /// stdio, and — through the `sh … &` — not the app's child, so nothing in
    /// the app has to reap it and quitting the app does not reach it.
    static func launch(binary: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)

        let arguments = ["/bin/sh", "-c", "\"$0\" pty-host </dev/null >/dev/null 2>&1 &", binary]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        guard result == 0 else { throw PTYHostError.unreachable("spawn: \(String(cString: strerror(result)))") }
        // The shell returns as soon as the host is backgrounded.
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

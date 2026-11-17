import Darwin
import Foundation

/// `Vitra pty-host`: the process that owns the project terminals, so they
/// outlive the app.
///
/// A shell whose pty master lives in the app gets SIGHUP when the app quits,
/// and the app quits every time it is reinstalled — taking the maestro's turn
/// with it. Here the masters and the children belong to a small detached
/// process instead; the app connects over a unix socket, one connection per
/// terminal, and proxies the bytes. Quitting the app only drops connections.
///
/// Everything runs on one serial queue: there is little work, and one queue
/// means no locks. One host per user, held by an flock on `paths.lock`, which
/// the kernel lets go of when the holder dies — so a lock or socket left by a
/// crashed host is simply taken over.
public final class PTYHost: @unchecked Sendable {
    public struct Limits: Sendable {
        /// With no session and no client for this long, the host leaves.
        public var idle: TimeInterval = 10 * 60
        /// A session whose child exited is forgotten after this long, if
        /// nobody closed it first.
        public var deadSession: TimeInterval = 60 * 60
        /// How much recent output each session keeps for a re-attach.
        public var replay = 2 * 1024 * 1024
        /// How often the two limits above are looked at.
        public var sweep: TimeInterval = 60
        /// How long a client may take to accept a write before it is dropped.
        public var clientWrite: TimeInterval = 2

        public init() {}
    }

    private let paths: PTYHostPaths
    private let limits: Limits
    private let onExit: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.vitra.pty-host")

    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sweepTimer: DispatchSourceTimer?
    private var sessions: [String: HostedSession] = [:]
    private var clients: [ObjectIdentifier: HostClient] = [:]
    private var lastBusy = Date()
    private var isStopped = false

    /// `onExit` runs, on the host's queue, once the host has stopped by itself:
    /// idle for too long, or told to `shutdown`.
    public init(paths: PTYHostPaths = .standard, limits: Limits = Limits(), onExit: @escaping @Sendable () -> Void = {}) {
        self.paths = paths
        self.limits = limits
        self.onExit = onExit
    }

    /// The `pty-host` subcommand: serves until idle or shut down, then exits.
    /// Leaves quietly when another host already holds the lock.
    public static func serveForever(paths: PTYHostPaths = .standard) -> Never {
        // A client that vanished mid-write must be an error, not a signal;
        // the host has no terminal, so a hangup means nothing to it either.
        // The children get default dispositions back in the spawn.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let host = PTYHost(paths: paths, onExit: { exit(0) })
        do { try host.start() } catch { exit(0) }
        dispatchMain()
    }

    public func start() throws {
        try queue.sync {
            try paths.prepare()
            let fd = Darwin.open(paths.lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw PTYHostError.unreachable("lock: \(String(cString: strerror(errno)))") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd)
                throw PTYHostError.refused("another pty-host is running")
            }
            // Holding the lock means no live host owns the socket: whatever is
            // at that path is a dead one's, and is replaced.
            ftruncate(fd, 0)
            PTYHostSocket.writeAll(fd, Data("\(getpid())\n".utf8))
            lockFD = fd
            unlink(paths.socket)
            do {
                listenFD = try PTYHostSocket.listen(at: paths.socket)
            } catch {
                Darwin.close(fd)
                lockFD = -1
                throw error
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptOne() }
            source.resume()
            acceptSource = source

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + limits.sweep, repeating: limits.sweep)
            timer.setEventHandler { [weak self] in self?.sweep(now: Date()) }
            timer.resume()
            sweepTimer = timer
            lastBusy = Date()
        }
    }

    /// Ends every session and lets go of the socket and the lock.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        guard !isStopped else { return }
        isStopped = true
        acceptSource?.cancel()
        acceptSource = nil
        sweepTimer?.cancel()
        sweepTimer = nil
        clients.values.forEach(drop)
        sessions.values.forEach { $0.end(on: queue) }
        sessions = [:]
        if listenFD >= 0 {
            Darwin.close(listenFD)
            unlink(paths.socket)
            listenFD = -1
        }
        if lockFD >= 0 {
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    // MARK: - Clients

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard PTYHostSocket.admits(peer: PTYHostSocket.peerUID(of: fd)) else {
            Darwin.close(fd)
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Bounds writes: an app that stops reading is dropped, not waited on.
        PTYHostSocket.setTimeout(fd, limits.clientWrite)

        let client = HostClient(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.readFrom(client)
        }
        source.setCancelHandler { Darwin.close(fd) }
        client.source = source
        clients[ObjectIdentifier(client)] = client
        lastBusy = Date()
        source.resume()
    }

    private func readFrom(_ client: HostClient) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { Darwin.read(client.fd, $0.baseAddress, $0.count) }
        guard n > 0 else {
            if n < 0, errno == EINTR || errno == EAGAIN { return }
            drop(client)
            return
        }
        client.buffer.append(contentsOf: chunk[0..<n])
        do {
            while !client.isClosed, let frame = try PTYHostProtocol.nextFrame(from: &client.buffer) {
                handle(frame.kind, frame.body, from: client)
            }
        } catch {
            drop(client)
        }
    }

    private func drop(_ client: HostClient) {
        guard !client.isClosed else { return }
        client.isClosed = true
        client.source?.cancel()
        client.source = nil
        if client.session?.client === client { client.session?.client = nil }
        client.session = nil
        clients.removeValue(forKey: ObjectIdentifier(client))
        lastBusy = Date()
    }

    private func send(_ data: Data, to client: HostClient) {
        guard !client.isClosed else { return }
        if !PTYHostSocket.writeAll(client.fd, data) { drop(client) }
    }

    private func reply(_ message: PTYHostMessage, to client: HostClient) {
        send(PTYHostProtocol.frame(message), to: client)
    }

    // MARK: - Messages

    private func handle(_ kind: PTYHostProtocol.Kind?, _ body: Data, from client: HostClient) {
        switch kind {
        case .input:
            guard let session = client.session, session.isAlive else { return }
            body.withUnsafeBytes { try? session.pty.write($0) }
        case .control:
            guard let message = try? JSONDecoder().decode(PTYHostMessage.self, from: body) else {
                reply(PTYHostMessage(op: "error", message: "unreadable message"), to: client)
                return
            }
            handle(message, from: client)
        case .output, .replay, nil:
            // Not the app's to send, or from a newer app; ignored either way.
            break
        }
    }

    private func handle(_ message: PTYHostMessage, from client: HostClient) {
        switch message.op {
        case "hello":
            reply(PTYHostMessage(op: "hello", version: PTYHostProtocol.version, pid: getpid()), to: client)
        case "open":
            open(message, for: client)
        case "attach":
            guard let id = message.id, let session = sessions[id] else {
                reply(PTYHostMessage(op: "error", id: message.id, message: "unknown session"), to: client)
                return
            }
            attach(client, to: session, created: false)
        case "resize":
            guard let session = message.id.flatMap({ sessions[$0] }) ?? client.session, session.isAlive,
                  let cols = message.cols, let rows = message.rows
            else { return }
            session.pty.resize(to: TerminalSize(columns: UInt16(clamping: cols), rows: UInt16(clamping: rows)))
        case "close":
            if let id = message.id ?? client.session?.id, let session = sessions.removeValue(forKey: id) {
                session.end(on: queue)
            }
            reply(PTYHostMessage(op: "ok"), to: client)
        case "list":
            let list = sessions.values.sorted { $0.started < $1.started }.map(\.info)
            reply(PTYHostMessage(op: "list", sessions: list), to: client)
        case "shutdown":
            reply(PTYHostMessage(op: "ok"), to: client)
            stopOnQueue()
            onExit()
        default:
            reply(PTYHostMessage(op: "error", message: "unknown op \(message.op)"), to: client)
        }
    }

    /// Attaches to the live session with this id, or starts one. A session
    /// whose child has exited is replaced: whoever asks again wants a shell.
    private func open(_ message: PTYHostMessage, for client: HostClient) {
        guard let id = message.id, let argv = message.argv, let executable = argv.first else {
            reply(PTYHostMessage(op: "error", id: message.id, message: "open needs id and argv"), to: client)
            return
        }
        if let session = sessions[id], session.isAlive {
            attach(client, to: session, created: false)
            return
        }
        let size = TerminalSize(columns: UInt16(clamping: message.cols ?? 80), rows: UInt16(clamping: message.rows ?? 24))
        let pty: PTY
        do {
            pty = try PTY(
                executable: executable,
                arguments: Array(argv.dropFirst()),
                environment: message.env ?? [:],
                size: size,
                workingDirectory: message.cwd
            )
        } catch {
            reply(PTYHostMessage(op: "error", id: id, message: "\(error)"), to: client)
            return
        }
        sessions[id]?.client.map(drop)
        let session = HostedSession(id: id, cwd: message.cwd ?? "", pty: pty)
        sessions[id] = session
        // Strong captures: the session lives until its child does. The PTY
        // lets go of these closures once the child has exited.
        pty.startReading(
            on: queue,
            onData: { [weak self] bytes in
                guard let self else { return }
                let data = Data(bytes)
                session.record(data, keeping: self.limits.replay)
                if let client = session.client {
                    self.send(PTYHostProtocol.frame(.output, data), to: client)
                }
            },
            onEOF: { [weak self] in
                session.exitStatus = session.pty.reap(blocking: true)
                session.exitedAt = Date()
                if let self, let client = session.client {
                    self.reply(PTYHostMessage(op: "exited", id: session.id, status: session.exitStatus), to: client)
                }
            }
        )
        attach(client, to: session, created: true)
    }

    /// Binds `client` to `session`: the reply, then what the session said
    /// recently, then — if it has already ended — how. One client per session;
    /// a newer one takes over, since the older is an app that has gone.
    private func attach(_ client: HostClient, to session: HostedSession, created: Bool) {
        if let previous = session.client, previous !== client { drop(previous) }
        session.client = client
        client.session = session
        reply(PTYHostMessage(op: "attached", id: session.id, pid: session.pty.processID, created: created), to: client)
        var offset = session.recent.startIndex
        while offset < session.recent.endIndex, !client.isClosed {
            let end = min(offset + PTYHostProtocol.chunk, session.recent.endIndex)
            send(PTYHostProtocol.frame(.replay, Data(session.recent[offset..<end])), to: client)
            offset = end
        }
        if !session.isAlive {
            reply(PTYHostMessage(op: "exited", id: session.id, status: session.exitStatus), to: client)
        }
    }

    // MARK: - Housekeeping

    /// Forgets long-dead sessions, and leaves when there has been nothing to
    /// do for long enough.
    private func sweep(now: Date) {
        for (id, session) in sessions {
            if let exited = session.exitedAt, now.timeIntervalSince(exited) >= limits.deadSession {
                sessions.removeValue(forKey: id)
            }
        }
        guard sessions.isEmpty, clients.isEmpty else {
            lastBusy = now
            return
        }
        if now.timeIntervalSince(lastBusy) >= limits.idle {
            stopOnQueue()
            onExit()
        }
    }
}

// Both below are only ever touched on the host's queue.

/// A connection from an app; bound to at most one session.
private final class HostClient: @unchecked Sendable {
    let fd: Int32
    var source: DispatchSourceRead?
    var buffer = Data()
    var session: HostedSession?
    var isClosed = false

    init(fd: Int32) { self.fd = fd }
}

/// One terminal the host owns: the pty, its child, and what it said last.
private final class HostedSession: @unchecked Sendable {
    let id: String
    let cwd: String
    let pty: PTY
    let started = Date()
    private(set) var recent = Data()
    var exitStatus: Int32?
    var exitedAt: Date?
    var client: HostClient?

    var isAlive: Bool { exitedAt == nil }

    var info: PTYHostSessionInfo {
        PTYHostSessionInfo(id: id, cwd: cwd, pid: pty.processID, alive: isAlive, started: started)
    }

    init(id: String, cwd: String, pty: PTY) {
        self.id = id
        self.cwd = cwd
        self.pty = pty
    }

    /// Keeps the last `limit` bytes. Trimmed in steps, not on every write,
    /// so a firehose does not copy two megabytes per read.
    func record(_ data: Data, keeping limit: Int) {
        recent.append(data)
        if recent.count > limit + limit / 8 { recent = Data(recent.suffix(limit)) }
    }

    /// Hangs up on the child, and kills it if it will not go. Its exit is
    /// still reported to whoever is attached.
    func end(on queue: DispatchQueue) {
        guard isAlive else { return }
        pty.terminate()
        let pid = pty.processID
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.isAlive == true { kill(pid, SIGKILL) }
        }
    }
}

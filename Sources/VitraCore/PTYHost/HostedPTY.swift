import Darwin
import Foundation

/// A terminal whose child lives in `Vitra pty-host`, so it survives the app.
///
/// Built synchronously like a `PTY`, so nothing that makes a terminal has to
/// wait; the connection is made off the main thread once reading starts. If
/// the host cannot be reached within `PTYHostClient.patience`, or speaks
/// another protocol version, the child is started in-process instead, exactly
/// as a plain `PTY` would — the user gets a terminal either way, and
/// `onReady` says which kind.
///
/// Input, resizes and the stream are handled on the session's queue, which is
/// where `TerminalSession` calls in from; the socket is read on a queue of its
/// own, so a busy session can never stall the host's writes to it.
public final class HostedPTY: TerminalBackend, @unchecked Sendable {
    public struct Spec: Sendable {
        /// Stable across launches: it is how the next app finds this session.
        public var id: String
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: String?
        public var size: TerminalSize

        public init(id: String, executable: String, arguments: [String], environment: [String: String], workingDirectory: String?, size: TerminalSize) {
            self.id = id
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.size = size
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// The host had this session running: it was picked up where it was.
        case attached
        /// The host started a new child.
        case created
        /// No usable host; the child runs in this process.
        case local
    }

    /// Told once, on the main queue, what kind of terminal this turned out to be.
    public var onReady: (@Sendable (Outcome) -> Void)?

    private enum State {
        case pending
        case remote(fd: Int32, pid: pid_t, source: DispatchSourceRead)
        case local(PTY)
        case closed
    }

    private let spec: Spec
    private let paths: PTYHostPaths
    private let binary: String?
    private let lock = NSLock()
    private let readQueue = DispatchQueue(label: "dev.vitra.hosted-pty.read")

    // Guarded by `lock`: read from the main thread for the kernel queries.
    private var state = State.pending
    private var exitStatus: Int32?
    private var sessionQueue: DispatchQueue?

    // Only touched on the read queue.
    private var readBuffer = Data()

    // Only touched on the session's queue.
    private var onData: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    private var onEOF: (@Sendable () -> Void)?
    private var pendingInput: [Data] = []
    private var pendingSize: TerminalSize?
    private var endRequested: End?
    private var hasEnded = false
    public private(set) var isReplaying = false

    private enum End { case terminate, detach }

    /// `binary` is what starts a host when none is running; nil only connects.
    public init(spec: Spec, paths: PTYHostPaths = .standard, binary: String?) {
        self.spec = spec
        self.paths = paths
        self.binary = binary
    }

    /// Whether the child lives in the host, and so outlives the app.
    public var isInHost: Bool {
        lock.withLock { if case .remote = state { true } else { false } }
    }

    // MARK: - TerminalBackend

    public func startReading(
        on queue: DispatchQueue,
        onData: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        lock.withLock { sessionQueue = queue }
        queue.async {
            self.onData = onData
            self.onEOF = onEOF
            guard case .pending = self.lock.withLock({ self.state }) else { return }
            DispatchQueue.global(qos: .userInitiated).async { self.connect(queue: queue) }
        }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        switch lock.withLock({ state }) {
        case .pending:
            pendingInput.append(Data(bytes))
        case let .remote(fd, _, _):
            PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(.input, Data(bytes)))
        case let .local(pty):
            try pty.write(bytes)
        case .closed:
            break
        }
    }

    public func resize(to size: TerminalSize) {
        switch lock.withLock({ state }) {
        case .pending:
            pendingSize = size
        case let .remote(fd, _, _):
            PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(PTYHostMessage(op: "resize", cols: Int(size.columns), rows: Int(size.rows))))
        case let .local(pty):
            pty.resize(to: size)
        case .closed:
            break
        }
    }

    /// Closes the session in the host: the child is hung up on, and its exit
    /// comes back like any other.
    public func terminate() {
        if case let .local(pty) = lock.withLock({ state }) { return pty.terminate() }
        onSessionQueue { self.end(.terminate) }
    }

    /// Drops the connection; the host keeps the child and its output for the
    /// next app to attach to.
    public func detach() {
        if case let .local(pty) = lock.withLock({ state }) { return pty.terminate() }
        onSessionQueue { self.end(.detach) }
    }

    public func close() {
        if case let .local(pty) = lock.withLock({ state }) { return pty.close() }
        // After anything already queued — a `close` to the host above all.
        onSessionQueue { self.end(.detach) }
    }

    public func reap(blocking: Bool) -> Int32? {
        switch lock.withLock({ state }) {
        case let .local(pty): pty.reap(blocking: blocking)
        default: lock.withLock { exitStatus }
        }
    }

    // MARK: - Kernel queries

    // The child is not ours, but it is the same user's: the kernel answers
    // about it all the same. Only the tty's foreground group needs another
    // route, since `tcgetpgrp` wants the master, which the host holds.

    public var workingDirectory: URL? {
        switch lock.withLock({ state }) {
        case let .local(pty): return pty.workingDirectory
        case let .remote(_, pid, _): return PTY.workingDirectory(of: Self.foregroundGroup(of: pid) ?? pid)
        default: return nil
        }
    }

    public var foregroundName: String? {
        switch lock.withLock({ state }) {
        case let .local(pty): return pty.foregroundName
        case let .remote(_, pid, _): return PTY.programName(of: Self.foregroundGroup(of: pid) ?? pid)
        default: return nil
        }
    }

    public var hasForegroundJob: Bool {
        switch lock.withLock({ state }) {
        case let .local(pty): return pty.hasForegroundJob
        case let .remote(_, pid, _): return Self.foregroundGroup(of: pid).map { $0 != pid } ?? false
        default: return false
        }
    }

    /// The process group in the foreground of `pid`'s controlling tty.
    static func foregroundGroup(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tpgid > 0 else { return nil }
        return pid_t(info.e_tpgid)
    }

    // MARK: - Connecting

    /// Off the main thread: reach the host, open or attach, then settle the
    /// state on the session's queue.
    private func connect(queue: DispatchQueue) {
        do {
            var (fd, buffer) = try PTYHostClient.connect(paths: paths, launching: binary, deadline: Date() + PTYHostClient.patience)
            let size = queue.sync { pendingSize ?? spec.size }
            let open = PTYHostMessage(
                op: "open", id: spec.id, cwd: spec.workingDirectory, env: spec.environment,
                argv: [spec.executable] + spec.arguments, cols: Int(size.columns), rows: Int(size.rows)
            )
            guard PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(open)) else {
                Darwin.close(fd)
                throw PTYHostError.unreachable("open not sent")
            }
            let reply: PTYHostMessage
            do { reply = try PTYHostSocket.readMessage(fd, buffer: &buffer) } catch {
                Darwin.close(fd)
                throw error
            }
            guard reply.op == "attached", let pid = reply.pid else {
                Darwin.close(fd)
                throw PTYHostError.refused(reply.message ?? reply.op)
            }
            let (connected, leftover, created) = (fd, buffer, reply.created == true)
            queue.async { self.settleRemote(fd: connected, pid: pid, created: created, leftover: leftover) }
        } catch {
            queue.async { self.settleLocal() }
        }
    }

    private func settleRemote(fd: Int32, pid: pid_t, created: Bool, leftover: Data) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR || errno == EAGAIN { return }
            if n > 0 { self?.readBuffer.append(contentsOf: chunk[0..<n]) }
            self?.deliverFrames(hostGone: n <= 0)
        }
        source.setCancelHandler { Darwin.close(fd) }
        lock.withLock { state = .remote(fd: fd, pid: pid, source: source) }

        // What was asked for before the connection: a resize first, so the
        // child draws for the size it will be seen at, then the typing.
        if let pendingSize, pendingSize != spec.size { resize(to: pendingSize) }
        pendingInput.forEach { data in data.withUnsafeBytes { try? write($0) } }
        pendingInput = []
        // Frames that came with the reply are not announced by the source:
        // they go first, then the source takes over.
        readQueue.async {
            self.readBuffer = leftover
            self.deliverFrames(hostGone: false)
            source.resume()
        }

        if let end = endRequested { self.end(end) } else { report(created ? .created : .attached) }
    }

    private func settleLocal() {
        if let end = endRequested {
            // Ended before it began: no child is started. A terminate is
            // still reported as the end it asked for.
            lock.withLock { state = .closed }
            if end == .terminate { deliverEOF() }
            return
        }
        do {
            let pty = try PTY(
                executable: spec.executable,
                arguments: spec.arguments,
                environment: spec.environment,
                size: pendingSize ?? spec.size,
                workingDirectory: spec.workingDirectory
            )
            lock.withLock { state = .local(pty) }
            if let sessionQueue, let onData, let onEOF {
                pty.startReading(on: sessionQueue, onData: onData, onEOF: onEOF)
            }
            pendingInput.forEach { data in data.withUnsafeBytes { try? pty.write($0) } }
            pendingInput = []
            report(.local)
        } catch {
            lock.withLock { state = .closed }
            deliverEOF()
        }
    }

    private func report(_ outcome: Outcome) {
        guard let onReady else { return }
        DispatchQueue.main.async { onReady(outcome) }
    }

    // MARK: - The stream

    /// On the read queue: hands each frame to the session's queue, in order.
    private func deliverFrames(hostGone: Bool) {
        guard let queue = lock.withLock({ sessionQueue }) else { return }
        do {
            while let frame = try PTYHostProtocol.nextFrame(from: &readBuffer) {
                switch frame.kind {
                case .output:
                    queue.async { frame.body.withUnsafeBytes { self.onData?($0) } }
                case .replay:
                    queue.async {
                        self.isReplaying = true
                        frame.body.withUnsafeBytes { self.onData?($0) }
                        self.isReplaying = false
                    }
                case .control:
                    guard let message = try? JSONDecoder().decode(PTYHostMessage.self, from: frame.body),
                          message.op == "exited" else { continue }
                    queue.async {
                        // The session is over; so is this connection. The
                        // host forgets it when the next `open` replaces it.
                        let source = self.lock.withLock { () -> DispatchSourceRead? in
                            self.exitStatus = message.status
                            guard case let .remote(_, _, source) = self.state else { return nil }
                            self.state = .closed
                            return source
                        }
                        source?.cancel()
                        self.deliverEOF()
                    }
                case .input, nil:
                    continue
                }
            }
        } catch {
            return queue.async { self.hostWentAway() }
        }
        if hostGone { queue.async { self.hostWentAway() } }
    }

    /// The host died or dropped us: to the terminal that is its child ending.
    private func hostWentAway() {
        guard case let .remote(_, _, source) = lock.withLock({ state }) else { return }
        source.cancel()
        lock.withLock { state = .closed }
        deliverEOF()
    }

    private func deliverEOF() {
        guard !hasEnded else { return }
        hasEnded = true
        onEOF?()
    }

    // MARK: - Ending

    private func onSessionQueue(_ work: @escaping @Sendable () -> Void) {
        guard let sessionQueue = lock.withLock({ sessionQueue }) else {
            // Never started: there is no connection to end.
            lock.withLock { state = .closed }
            return
        }
        sessionQueue.async(execute: work)
    }

    /// On the session's queue. Before the connection is settled the request
    /// is kept, and carried out when it is.
    private func end(_ how: End) {
        switch lock.withLock({ state }) {
        case .pending:
            // A terminate is not undone by the close that follows it.
            if endRequested != .terminate { endRequested = how }
        case let .remote(fd, _, source):
            if how == .terminate {
                // The host answers with `exited`; until it does, keep reading.
                PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(PTYHostMessage(op: "close")))
                return
            }
            source.cancel()
            lock.withLock { state = .closed }
        case let .local(pty):
            how == .terminate ? pty.terminate() : pty.close()
        case .closed:
            break
        }
    }
}

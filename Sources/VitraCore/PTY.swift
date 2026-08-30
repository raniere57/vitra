import Darwin
import Foundation

public enum PTYError: Error, CustomStringConvertible {
    case openFailed(errno: Int32)
    case spawnFailed(errno: Int32)
    case writeFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .openFailed(code):
            return "openpty failed: \(String(cString: strerror(code)))"
        case let .spawnFailed(code):
            return "posix_spawn failed: \(String(cString: strerror(code)))"
        case let .writeFailed(code):
            return "pty write failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A pseudo-terminal with a child process attached to its slave side.
///
/// The child is started with `posix_spawn(2)` rather than `forkpty(3)`. The
/// earlier fork-based version wrote the child's setup in Swift, and calling into
/// the Swift runtime between fork and exec is unsafe in a process with other
/// threads: a metadata lookup takes a lock another thread held at fork time, and
/// the kernel kills the child before it ever execs. That was reproducible under
/// load — "crashed on child side of fork pre-exec", os_unfair_lock corrupt —
/// and it would have shown up as a pane that opens dead.
///
/// The properties `login_tty()` provided are kept: `POSIX_SPAWN_SETSID` makes the
/// child a session leader, and the first file action opens the slave *by path*
/// without `O_NOCTTY`, which is what makes that tty the child's controlling
/// terminal. Without one there is no job control, so Ctrl-C, `fg`, and `bg` break.
///
/// Access must be serialized by the caller, so this is `@unchecked Sendable`:
/// the compiler cannot see the queue discipline that makes it safe.
public final class PTY: @unchecked Sendable {
    public let masterFD: Int32
    public let processID: pid_t

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var readBuffer: UnsafeMutableRawPointer
    private let readBufferSize = 64 * 1024
    private var isClosed = false

    /// The parent's own descriptor onto the slave side.
    ///
    /// Once the child exits and the last slave descriptor closes, Darwin tears
    /// the pty down and discards output that was still buffered — a short-lived
    /// command's entire result can vanish. Holding this open keeps that data
    /// readable until we drop it deliberately, after draining. The child gets a
    /// separate descriptor of its own, opened by the spawn's file actions.
    private var slaveFD: Int32 = -1

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        size: TerminalSize
    ) throws {
        // argv/envp are C arrays because posix_spawn takes them that way; they
        // are freed once the child has been started.
        let path = strdup(executable)!
        let argv = Self.makeCArray([executable] + arguments)
        let envp = Self.makeCArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            free(path)
            Self.freeCArray(argv)
            Self.freeCArray(envp)
        }

        var ws = winsize(
            ws_row: size.rows,
            ws_col: size.columns,
            ws_xpixel: size.pixelWidth,
            ws_ypixel: size.pixelHeight
        )

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
            throw PTYError.openFailed(errno: errno)
        }

        // ttyname() returns a pointer into per-thread storage that the next call
        // overwrites, so the path is copied before it is handed to the spawn.
        guard let name = ttyname(slave).map({ strdup($0) }) else {
            Darwin.close(master)
            Darwin.close(slave)
            throw PTYError.openFailed(errno: errno)
        }
        defer { free(name) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Opened by path, after SETSID and without O_NOCTTY: that is what makes
        // this tty the child's controlling terminal. Inheriting a descriptor
        // would not — a controlling terminal is acquired by opening one.
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // CLOEXEC_DEFAULT closes every descriptor the file actions do not name,
        // so nothing the app had open — including this pty's own master — leaks
        // into the shell and from there into everything the user runs.
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        ))

        // A GUI process ignores SIGPIPE and may block signals; shells expect
        // default dispositions and an empty mask.
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard result == 0 else {
            Darwin.close(master)
            Darwin.close(slave)
            // posix_spawn reports through its return value, not errno.
            throw PTYError.spawnFailed(errno: result)
        }

        self.masterFD = master
        self.processID = pid
        self.slaveFD = slave
        self.readBuffer = .allocate(byteCount: readBufferSize, alignment: MemoryLayout<UInt8>.alignment)

        // Non-blocking so a full read loop can drain to EAGAIN in one wakeup and
        // so draining after child exit can never block the session queue.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
    }

    deinit {
        readBuffer.deallocate()
        if !isClosed {
            if slaveFD >= 0 { Darwin.close(slaveFD) }
            Darwin.close(masterFD)
        }
    }

    // MARK: - I/O

    /// Starts delivering PTY output on `queue` until the child exits.
    ///
    /// The read buffer is owned by the PTY and reused across reads, so `onData`
    /// must not escape the pointer it receives. `onEOF` fires only after every
    /// remaining byte has been handed to `onData`.
    public func startReading(
        on queue: DispatchQueue,
        onData: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(onData)
        }
        source.resume()
        readSource = source

        // Child exit, not read()'s EOF, is what ends a session: the parent holds a
        // slave descriptor open, so the master would otherwise never report EOF.
        let exit = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            // Drain, then release the slave and drain again: anything the child
            // wrote just before exiting is still buffered and still the user's.
            self.drain(onData)
            if self.slaveFD >= 0 { Darwin.close(self.slaveFD); self.slaveFD = -1 }
            self.drain(onData)
            self.close()
            onEOF()
        }
        exit.resume()
        exitSource = exit
    }

    /// Reads until the master has nothing more to give right now.
    private func drain(_ onData: (UnsafeRawBufferPointer) -> Void) {
        guard !isClosed else { return }
        while true {
            let n = read(masterFD, readBuffer, readBufferSize)
            if n > 0 {
                onData(UnsafeRawBufferPointer(start: readBuffer, count: n))
                continue
            }
            if n < 0 && errno == EINTR { continue }
            // n == 0 is EOF; EAGAIN means empty for now; EIO means the pty is gone.
            return
        }
    }

    /// Writes bytes to the child's stdin, retrying short writes.
    ///
    /// ponytail: blocking write. A very large paste can stall the caller if the
    /// child stops reading; add an outbound queue when that shows up in practice.
    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(masterFD, base + offset, bytes.count - offset)
            if n > 0 { offset += n; continue }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                // The child is not draining fast enough. Wait for room rather than
                // spinning on a non-blocking descriptor.
                var fd = pollfd(fd: masterFD, events: Int16(POLLOUT), revents: 0)
                _ = poll(&fd, 1, 100)
                continue
            }
            throw PTYError.writeFailed(errno: errno)
        }
    }

    public func write(_ string: String) throws {
        var copy = string
        try copy.withUTF8 { try write(UnsafeRawBufferPointer($0)) }
    }

    /// Updates the kernel's window size, which makes it deliver SIGWINCH to the
    /// child's foreground process group.
    public func resize(to size: TerminalSize) {
        var ws = winsize(
            ws_row: size.rows,
            ws_col: size.columns,
            ws_xpixel: size.pixelWidth,
            ws_ypixel: size.pixelHeight
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    // MARK: - Lifecycle

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        if slaveFD >= 0 { Darwin.close(slaveFD); slaveFD = -1 }
        Darwin.close(masterFD)
    }

    public func terminate() {
        kill(processID, SIGHUP)
    }

    /// Reaps the child and returns its exit status, or nil if it has not exited.
    @discardableResult
    public func reap(blocking: Bool = false) -> Int32? {
        var status: Int32 = 0
        let result = waitpid(processID, &status, blocking ? 0 : WNOHANG)
        guard result == processID else { return nil }
        return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
    }

    // MARK: - C array helpers

    private static func makeCArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { buffer[index] = strdup(string) }
        buffer[strings.count] = nil
        return buffer
    }

    private static func freeCArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var index = 0
        while let entry = array[index] { free(entry); index += 1 }
        array.deallocate()
    }
}

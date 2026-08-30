import Darwin
import Foundation

public enum PTYError: Error, CustomStringConvertible {
    case forkFailed(errno: Int32)
    case writeFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .forkFailed(code):
            return "forkpty failed: \(String(cString: strerror(code)))"
        case let .writeFailed(code):
            return "pty write failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A pseudo-terminal with a child process attached to its slave side.
///
/// `forkpty(3)` is used rather than `posix_spawn` because only it performs
/// `login_tty()` in the child: `setsid()` plus `TIOCSCTTY`. Without a controlling
/// terminal the shell has no job control, so Ctrl-C, `fg`, and `bg` all break.
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

    /// A second descriptor onto the slave side, held open by the parent.
    ///
    /// `forkpty()` returns only the master. Once the child exits and the last
    /// slave descriptor closes, Darwin tears the pty down and discards output
    /// that was still buffered — a short-lived command's entire result can
    /// vanish. Holding this open keeps that data readable until we drop it
    /// deliberately, after draining.
    private var slaveFD: Int32 = -1

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        size: TerminalSize
    ) throws {
        // Every buffer the child touches is built before forkpty(). Between fork
        // and execve only async-signal-safe calls are legal, which rules out all
        // Swift allocation, ARC traffic, and String bridging.
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
        let pid = forkpty(&master, nil, nil, &ws)

        if pid < 0 { throw PTYError.forkFailed(errno: errno) }

        if pid == 0 {
            // --- child ---
            // A GUI process ignores SIGPIPE and may block signals; shells expect
            // default dispositions and an empty mask.
            for sig in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGTTIN, SIGTTOU, SIGWINCH] {
                signal(sig, SIG_DFL)
            }
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)

            // forkpty() dup2s the slave onto 0/1/2 and closes the master, but every
            // other descriptor the app had open is still inherited. Leaking those
            // into the shell leaks them into everything the user runs.
            let maxFD = getdtablesize()
            for fd in 3..<maxFD { Darwin.close(fd) }

            execve(path, argv, envp)
            _exit(127)
        }

        // --- parent ---
        self.masterFD = master
        self.processID = pid
        self.readBuffer = .allocate(byteCount: readBufferSize, alignment: MemoryLayout<UInt8>.alignment)

        // Non-blocking so a full read loop can drain to EAGAIN in one wakeup and
        // so draining after child exit can never block the session queue.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)

        if let name = ptsname(master) {
            slaveFD = open(name, O_RDWR | O_NOCTTY)
        }
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

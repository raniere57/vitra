import Darwin
import Foundation
import Testing
@testable import VitraCore

// The host is run in-process here, on a socket in a temporary folder: the
// same type `Vitra pty-host` runs, without a second binary to find.

/// A folder short enough for a unix socket path.
private func temporaryPaths() -> PTYHostPaths {
    let short = String(UUID().uuidString.prefix(8))
    return PTYHostPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vph-\(short)", isDirectory: true))
}

/// A host on a temporary socket, stopped when the test is done with it.
private func withHost<T>(limits: PTYHost.Limits = PTYHost.Limits(), _ body: (PTYHostPaths, PTYHost) throws -> T) throws -> T {
    let paths = temporaryPaths()
    let host = PTYHost(paths: paths, limits: limits)
    try host.start()
    defer {
        host.stop()
        try? FileManager.default.removeItem(at: paths.directory)
    }
    return try body(paths, host)
}

/// A raw connection, speaking the protocol by hand.
private final class Connection {
    let fd: Int32
    var buffer = Data()
    var output = Data()
    var messages: [PTYHostMessage] = []
    var replayed = Data()

    init(_ paths: PTYHostPaths) throws {
        (fd, buffer) = try PTYHostClient.handshake(paths: paths, deadline: Date() + 5)
        PTYHostSocket.setTimeout(fd, 0.2)
    }

    deinit { Darwin.close(fd) }

    func send(_ message: PTYHostMessage) { PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(message)) }
    func type(_ text: String) { PTYHostSocket.writeAll(fd, PTYHostProtocol.frame(.input, Data(text.utf8))) }

    /// Reads frames until `done` holds or `timeout` passes.
    @discardableResult
    func read(until done: (Connection) -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date() + timeout
        while !done(self), Date() < deadline {
            guard let frame = try? PTYHostSocket.readFrame(fd, buffer: &buffer) else { continue }
            switch frame.kind {
            case .output: output.append(frame.body)
            case .replay: replayed.append(frame.body)
            case .control: if let message = try? JSONDecoder().decode(PTYHostMessage.self, from: frame.body) { messages.append(message) }
            default: break
            }
        }
        return done(self)
    }

    var text: String { String(decoding: output, as: UTF8.self) }
    func message(_ op: String) -> PTYHostMessage? { messages.first { $0.op == op } }

    func open(_ id: String, _ argv: [String], cols: Int = 80, rows: Int = 24) -> PTYHostMessage? {
        send(PTYHostMessage(op: "open", id: id, cwd: NSTemporaryDirectory(), env: ShellEnvironment.childEnvironment(), argv: argv, cols: cols, rows: rows))
        read(until: { $0.message("attached") != nil || $0.message("error") != nil })
        return message("attached")
    }
}

// MARK: - Framing

@Test func framesRoundTripThroughAPartialBuffer() throws {
    let message = PTYHostMessage(op: "open", id: "maestro:/p", argv: ["/bin/sh"], cols: 80, rows: 24)
    var stream = PTYHostProtocol.frame(message) + PTYHostProtocol.frame(.input, Data("ls\n".utf8))
    var partial = stream.prefix(3)
    #expect(try PTYHostProtocol.nextFrame(from: &partial) == nil)

    let first = try #require(try PTYHostProtocol.nextFrame(from: &stream))
    #expect(first.kind == .control)
    #expect(try JSONDecoder().decode(PTYHostMessage.self, from: first.body) == message)
    let second = try #require(try PTYHostProtocol.nextFrame(from: &stream))
    #expect(second.kind == .input)
    #expect(second.body == Data("ls\n".utf8))
    #expect(stream.isEmpty)
}

@Test func aFrameOfAnUnknownKindIsSkippableNotFatal() throws {
    var stream = Data([0, 0, 0, 3, 99, 1, 2])
    let frame = try #require(try PTYHostProtocol.nextFrame(from: &stream))
    #expect(frame.kind == nil)
    #expect(frame.body == Data([1, 2]))
}

@Test func anAbsurdFrameLengthIsRefused() {
    var stream = Data([0xFF, 0xFF, 0xFF, 0xFF, 1])
    #expect(throws: PTYHostError.self) { try PTYHostProtocol.nextFrame(from: &stream) }
}

@Test func messagesIgnoreFieldsTheyDoNotKnow() throws {
    let json = Data(#"{"op":"attached","pid":12,"fromTheFuture":true}"#.utf8)
    let message = try JSONDecoder().decode(PTYHostMessage.self, from: json)
    #expect(message.op == "attached")
    #expect(message.pid == 12)
}

@Test func onlyTheSameVersionIsCompatible() {
    #expect(PTYHostProtocol.isCompatible(hostVersion: PTYHostProtocol.version))
    #expect(!PTYHostProtocol.isCompatible(hostVersion: PTYHostProtocol.version + 1))
    #expect(!PTYHostProtocol.isCompatible(hostVersion: nil))
}

@Test func onlyTheSameUserIsAdmitted() {
    #expect(PTYHostSocket.admits(peer: 501, own: 501))
    #expect(!PTYHostSocket.admits(peer: 502, own: 501))
    #expect(!PTYHostSocket.admits(peer: 0, own: 501))
    #expect(!PTYHostSocket.admits(peer: nil, own: 501))
}

// MARK: - The host

@Test func openedSessionStreamsOutputAndTakesInput() throws {
    try withHost { paths, _ in
        let connection = try Connection(paths)
        let attached = try #require(connection.open("cat", ["/bin/cat"]))
        #expect(attached.created == true)
        connection.type("ping-from-test\n")
        #expect(connection.read(until: { $0.text.contains("ping-from-test") }))
    }
}

@Test func reattachingReplaysWhatWasSaidAndKeepsTheChild() throws {
    try withHost { paths, _ in
        let first = try Connection(paths)
        let opened = try #require(first.open("replay", ["/bin/sh", "-c", "echo marker-one; exec cat"]))
        #expect(first.read(until: { $0.text.contains("marker-one") }))
        _ = first  // dropped: the app quit

        let second = try Connection(paths)
        second.send(PTYHostMessage(op: "attach", id: "replay"))
        #expect(second.read(until: { String(decoding: $0.replayed, as: UTF8.self).contains("marker-one") }))
        #expect(second.message("attached")?.created == false)
        #expect(second.message("attached")?.pid == opened.pid)

        // Asking to open it again is attaching too: no second child.
        let third = try Connection(paths)
        #expect(third.open("replay", ["/bin/sh"])?.pid == opened.pid)
        third.type("still-here\n")
        #expect(third.read(until: { $0.text.contains("still-here") }))
    }
}

@Test func resizeReachesTheChildsTerminal() throws {
    try withHost { paths, _ in
        let connection = try Connection(paths)
        _ = try #require(connection.open("size", ["/bin/sh"]))
        connection.send(PTYHostMessage(op: "resize", cols: 101, rows: 33))
        connection.type("stty size\n")
        #expect(connection.read(until: { $0.text.contains("33 101") }))
    }
}

@Test func childExitIsReportedAndRememberedUntilClosed() throws {
    try withHost { paths, _ in
        let connection = try Connection(paths)
        _ = try #require(connection.open("exit", ["/bin/sh", "-c", "exit 7"]))
        #expect(connection.read(until: { $0.message("exited") != nil }))
        #expect(connection.message("exited")?.status == 7)

        let listed = try PTYHostClient.list(paths: paths)
        #expect(listed.first { $0.id == "exit" }?.alive == false)

        // Attaching later still says how it ended.
        let later = try Connection(paths)
        later.send(PTYHostMessage(op: "attach", id: "exit"))
        #expect(later.read(until: { $0.message("exited") != nil }))
        #expect(later.message("exited")?.status == 7)

        try PTYHostClient.close(id: "exit", paths: paths)
        #expect(try PTYHostClient.list(paths: paths).isEmpty)
    }
}

@Test func closeEndsTheChild() throws {
    try withHost { paths, _ in
        let connection = try Connection(paths)
        let pid = try #require(connection.open("doomed", ["/bin/cat"])?.pid)
        try PTYHostClient.close(id: "doomed", paths: paths)
        #expect(connection.read(until: { $0.message("exited") != nil }))
        // Reaped by the host: the pid no longer names a process of ours.
        #expect(kill(pid, 0) != 0)
        #expect(try PTYHostClient.list(paths: paths).isEmpty)
    }
}

@Test func listDescribesEverySession() throws {
    try withHost { paths, _ in
        let one = try Connection(paths)
        let two = try Connection(paths)
        _ = try #require(one.open("maestro:/a", ["/bin/cat"]))
        _ = try #require(two.open("shared:/a", ["/bin/cat"]))
        let sessions = try PTYHostClient.list(paths: paths)
        #expect(Set(sessions.map(\.id)) == ["maestro:/a", "shared:/a"])
        #expect(sessions.allSatisfy { $0.alive && $0.pid > 0 && $0.cwd == NSTemporaryDirectory() })
    }
}

@Test func aDeadSessionIsForgottenAfterItsTime() throws {
    var limits = PTYHost.Limits()
    limits.deadSession = 0.2
    limits.sweep = 0.1
    try withHost(limits: limits) { paths, _ in
        let connection = try Connection(paths)
        _ = try #require(connection.open("brief", ["/usr/bin/true"]))
        #expect(connection.read(until: { $0.message("exited") != nil }))
        let deadline = Date() + 5
        while Date() < deadline, (try? PTYHostClient.list(paths: paths))?.isEmpty != true { usleep(50_000) }
        #expect(try PTYHostClient.list(paths: paths).isEmpty)
    }
}

@Test func anIdleHostLeavesByItself() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    var limits = PTYHost.Limits()
    limits.idle = 0.2
    limits.sweep = 0.1
    let left = DispatchSemaphore(value: 0)
    let host = PTYHost(paths: paths, limits: limits, onExit: { left.signal() })
    try host.start()
    #expect(left.wait(timeout: .now() + 5) == .success)
    #expect(!FileManager.default.fileExists(atPath: paths.socket))
}

@Test func aSecondHostIsRefusedAndAStaleOneIsReplaced() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    try paths.prepare()
    // What a crashed host leaves: a lock file nobody holds and a socket file
    // nobody listens on.
    try Data("99999\n".utf8).write(to: URL(fileURLWithPath: paths.lock))
    let stale = try PTYHostSocket.listen(at: paths.socket)
    Darwin.close(stale)
    #expect(throws: PTYHostError.self) { _ = try PTYHostClient.handshake(paths: paths, deadline: Date() + 1) }

    let host = PTYHost(paths: paths)
    try host.start()
    defer { host.stop() }
    _ = try PTYHostClient.handshake(paths: paths, deadline: Date() + 2)

    #expect(throws: PTYHostError.self) { try PTYHost(paths: paths).start() }
    // The refused one did not take the live one's socket away.
    _ = try PTYHostClient.handshake(paths: paths, deadline: Date() + 2)

    let mode = try FileManager.default.attributesOfItem(atPath: paths.directory.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    var info = stat()
    stat(paths.socket, &info)
    #expect(info.st_mode & 0o777 == 0o600)
}

// MARK: - The app's side

/// What a `HostedPTY` delivered, and how it came up.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var replayData = Data()
    let ended = DispatchSemaphore(value: 0)

    func append(_ bytes: UnsafeRawBufferPointer, replaying: Bool) {
        lock.withLock { replaying ? replayData.append(contentsOf: bytes) : data.append(contentsOf: bytes) }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    var replayed: String { lock.withLock { String(decoding: replayData, as: UTF8.self) } }

    func wait(for needle: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date() + timeout
        while Date() < deadline, !text.contains(needle) { usleep(20_000) }
        return text.contains(needle)
    }
}

private func startHosted(_ id: String, _ argv: [String], paths: PTYHostPaths) -> (HostedPTY, Collected, DispatchQueue) {
    let spec = HostedPTY.Spec(
        id: id, executable: argv[0], arguments: Array(argv.dropFirst()),
        environment: ShellEnvironment.childEnvironment(), workingDirectory: NSTemporaryDirectory(), size: .default
    )
    let backend = HostedPTY(spec: spec, paths: paths, binary: nil)
    let collected = Collected()
    let queue = DispatchQueue(label: "test.hosted")
    backend.startReading(
        on: queue,
        onData: { [unowned backend] in collected.append($0, replaying: backend.isReplaying) },
        onEOF: { collected.ended.signal() }
    )
    return (backend, collected, queue)
}

// `onReady` is told on the main queue, which a test need not be draining;
// the outcome is read from `isInHost` instead.

@Test func aHostedTerminalSurvivesDetachAndReplaysOnReattach() throws {
    try withHost { paths, _ in
        let (first, firstSeen, queue) = startHosted("survivor", ["/bin/sh", "-c", "echo first-life; exec cat"], paths: paths)
        #expect(firstSeen.wait(for: "first-life"))
        #expect(first.isInHost)
        // Asked of the kernel without the master, which the host holds.
        let named = Date() + 5
        while Date() < named, first.foregroundName != "cat" { usleep(20_000) }
        #expect(first.foregroundName == "cat")
        #expect(first.workingDirectory != nil)
        queue.sync { try? first.write("typed-before-detach\n") }
        #expect(firstSeen.wait(for: "typed-before-detach"))
        first.detach()
        queue.sync {}

        let (second, secondSeen, secondQueue) = startHosted("survivor", ["/bin/sh"], paths: paths)
        let deadline = Date() + 10
        while Date() < deadline, !secondSeen.replayed.contains("typed-before-detach") { usleep(20_000) }
        #expect(secondSeen.replayed.contains("first-life"))
        #expect(secondSeen.replayed.contains("typed-before-detach"))
        #expect(!secondSeen.text.contains("first-life"))
        secondQueue.sync { try? second.write("after-reattach\n") }
        #expect(secondSeen.wait(for: "after-reattach"))

        second.terminate()
        #expect(secondSeen.ended.wait(timeout: .now() + 10) == .success)
        let remaining = try PTYHostClient.list(paths: paths)
        #expect(remaining.isEmpty)
    }
}

@Test func anUnreachableHostFallsBackToALocalChild() throws {
    let paths = temporaryPaths()
    let (backend, seen, queue) = startHosted("nowhere", ["/bin/sh", "-c", "echo local-life; exec cat"], paths: paths)
    #expect(seen.wait(for: "local-life"))
    #expect(!backend.isInHost)
    queue.sync { try? backend.write("local-input\n") }
    #expect(seen.wait(for: "local-input"))
    backend.terminate()
    #expect(seen.ended.wait(timeout: .now() + 10) == .success)
}

// MARK: - The real subcommand

/// The built app binary, when this build has one that serves `pty-host` and
/// honours VITRA_PTY_HOST_DIR. Anything else is skipped rather than run: an
/// older binary would open the app's window, or use the user's own socket.
private func builtAppBinary() -> String? {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binary = root.appendingPathComponent(".build/debug/VitraApp").path
    guard let data = FileManager.default.contents(atPath: binary),
          data.range(of: Data("VITRA_PTY_HOST_DIR".utf8)) != nil
    else { return nil }
    return binary
}

@Test(.enabled(if: builtAppBinary() != nil, "needs the VitraApp binary built"))
func theRealSubcommandStartsDetachedServesAndShutsDown() throws {
    let binary = try #require(builtAppBinary())
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    var environment = ProcessInfo.processInfo.environment
    environment["VITRA_PTY_HOST_DIR"] = paths.directory.path

    try PTYHostClient.launch(binary: binary, environment: environment)
    var reached: (fd: Int32, buffer: Data)?
    let deadline = Date() + 10
    while reached == nil, Date() < deadline {
        reached = try? PTYHostClient.handshake(paths: paths, deadline: Date() + 1)
        if reached == nil { usleep(50_000) }
    }
    let (fd, _) = try #require(reached)
    Darwin.close(fd)
    let hello = try PTYHostClient.request(PTYHostMessage(op: "hello"), paths: paths)
    let pid = try #require(hello.pid)

    // Not ours: a session of its own (the launching shell's), and reparented
    // away from this process.
    #expect(getsid(pid) != getsid(0))
    var info = proc_bsdinfo()
    _ = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    #expect(pid_t(info.pbi_ppid) != getpid())

    let connection = try Connection(paths)
    _ = try #require(connection.open("real", ["/bin/cat"]))
    connection.type("through-the-real-host\n")
    #expect(connection.read(until: { $0.text.contains("through-the-real-host") }))

    try PTYHostClient.shutdown(paths: paths)
    let gone = Date() + 5
    while kill(pid, 0) == 0, Date() < gone { usleep(50_000) }
    #expect(kill(pid, 0) != 0)
}

@Test func anIncompatibleHostFallsBackToALocalChild() throws {
    let paths = temporaryPaths()
    try paths.prepare()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    // A host from the future: it answers hello with a version this app
    // does not speak.
    let listener = try PTYHostSocket.listen(at: paths.socket)
    defer { Darwin.close(listener) }
    DispatchQueue.global().async {
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { return }
        var buffer = Data()
        _ = try? PTYHostSocket.readMessage(peer, buffer: &buffer)
        PTYHostSocket.writeAll(peer, PTYHostProtocol.frame(PTYHostMessage(op: "hello", version: PTYHostProtocol.version + 1)))
        usleep(500_000)
        Darwin.close(peer)
    }
    #expect(throws: PTYHostError.self) { _ = try PTYHostClient.handshake(paths: paths, deadline: Date() + 2) }

    DispatchQueue.global().async {
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { return }
        var buffer = Data()
        _ = try? PTYHostSocket.readMessage(peer, buffer: &buffer)
        PTYHostSocket.writeAll(peer, PTYHostProtocol.frame(PTYHostMessage(op: "hello", version: PTYHostProtocol.version + 1)))
        usleep(500_000)
        Darwin.close(peer)
    }
    let (backend, seen, _) = startHosted("future", ["/bin/sh", "-c", "echo fallback-life; exec cat"], paths: paths)
    #expect(seen.wait(for: "fallback-life"))
    #expect(!backend.isInHost)
    backend.terminate()
    #expect(seen.ended.wait(timeout: .now() + 10) == .success)
}

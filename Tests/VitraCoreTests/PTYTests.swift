import Darwin
import Foundation
import Testing
@testable import VitraCore

/// Runs a command on a real pty and returns everything it wrote before exiting.
private func capture(
    _ executable: String,
    _ arguments: [String],
    size: TerminalSize = .default,
    timeout: TimeInterval = 5
) throws -> (output: String, status: Int32?) {
    let collected = Output()
    let finished = DispatchSemaphore(value: 0)
    let pty = try PTY(
        executable: executable,
        arguments: arguments,
        environment: ShellEnvironment.childEnvironment(),
        size: size
    )
    pty.startReading(
        on: DispatchQueue(label: "test.pty"),
        onData: { collected.append($0) },
        onEOF: { finished.signal() }
    )
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        pty.terminate()
        Issue.record("pty did not reach EOF within \(timeout)s")
    }
    return (collected.text, pty.reap(blocking: true))
}

@Test func childOutputReachesTheMasterSide() throws {
    let result = try capture("/bin/echo", ["hello", "pty"])
    #expect(result.output.contains("hello pty"))
    #expect(result.status == 0)
}

@Test func childExitStatusIsReported() throws {
    #expect(try capture("/bin/sh", ["-c", "exit 3"]).status == 3)
}

@Test func killedChildReportsSignalStatus() throws {
    // 128 + SIGTERM, the shell convention.
    #expect(try capture("/bin/sh", ["-c", "kill -TERM $$"]).status == 128 + Int32(SIGTERM))
}

@Test func missingExecutableExitsWith127() throws {
    // execve() failing in the child must not take the parent down with it.
    #expect(try capture("/nonexistent/binary", []).status == 127)
}

@Test func childSeesTheWindowSizeItWasGiven() throws {
    let size = TerminalSize(columns: 132, rows: 43)
    let result = try capture("/bin/stty", ["size"], size: size)
    #expect(result.output.contains("43 132"))
}

@Test func resizeDeliversSIGWINCHToTheChild() throws {
    let pty = try PTY(
        executable: "/bin/sh",
        arguments: ["-c", "trap 'stty size; exit 0' WINCH; sleep 5 & wait"],
        environment: ShellEnvironment.childEnvironment(),
        size: TerminalSize(columns: 80, rows: 24)
    )
    let collected = Output()
    let finished = DispatchSemaphore(value: 0)
    pty.startReading(
        on: DispatchQueue(label: "test.pty.winch"),
        onData: { collected.append($0) },
        onEOF: { finished.signal() }
    )

    // Give the shell time to install its trap before changing the size.
    Thread.sleep(forTimeInterval: 0.3)
    pty.resize(to: TerminalSize(columns: 100, rows: 30))

    if finished.wait(timeout: .now() + 5) == .timedOut {
        pty.terminate()
        Issue.record("child never reported the new size")
    }
    #expect(collected.text.contains("30 100"))
}

@Test func childDoesNotInheritExtraDescriptors() throws {
    // A GUI process has many descriptors open; leaking them into the shell leaks
    // them into every command the user runs. The marker sits at a high number so
    // it cannot be confused with descriptors the child opens for itself.
    let marker: Int32 = 31
    let opened = open("/dev/null", O_RDONLY)
    #expect(opened >= 0)
    #expect(dup2(opened, marker) == marker)
    close(opened)
    defer { close(marker) }

    let result = try capture("/bin/sh", ["-c", "echo marker=$(ls /dev/fd/\(marker) 2>/dev/null || echo absent)"])
    #expect(result.output.contains("marker=absent"))
}

private final class Output: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ bytes: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        data.append(contentsOf: bytes)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

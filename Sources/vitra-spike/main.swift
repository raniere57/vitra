// vitra-spike — headless proof that the PTY and libghostty-vt agree on screen state.
//
// Runs a command on a real pty, feeds every byte through the terminal emulator,
// and prints the resulting viewport as plain text. No pixels, no window: this
// exists so terminal behaviour can be verified before any renderer exists.
//
//   swift run vitra-spike            # runs `ls -la`
//   swift run vitra-spike -- echo hi

import Darwin
import Foundation
import VitraCore
import VitraGhostty

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? ["/bin/ls", "-la"] : arguments
let size = TerminalSize(columns: 80, rows: 24)

let core = try GhosttyTerminalCore(size: size)
let pty = try PTY(
    executable: command[0],
    arguments: Array(command.dropFirst()),
    environment: ShellEnvironment.childEnvironment(),
    size: size
)

// libghostty requires serialized access to the terminal, so everything that
// touches the core — feeding input and answering queries — runs on this queue.
let queue = DispatchQueue(label: "dev.vitra.spike.session")

core.onWritePTY = { bytes in
    try? pty.write(bytes)
}
core.onTitleChanged = { title in
    FileHandle.standardError.write(Data("[title] \(title)\n".utf8))
}

// Byte and chunk counts make it possible to tell "fast" from "silently dropped
// half the input" when measuring throughput.
let counter = ByteCounter()
let finished = DispatchSemaphore(value: 0)
let started = DispatchTime.now()
pty.startReading(
    on: queue,
    onData: { bytes in
        counter.add(bytes.count)
        core.feed(bytes)
    },
    onEOF: { finished.signal() }
)

let timeout = ProcessInfo.processInfo.environment["VITRA_SPIKE_TIMEOUT"].flatMap(Double.init) ?? 5
if finished.wait(timeout: .now() + timeout) == .timedOut {
    FileHandle.standardError.write(Data("[spike] timed out waiting for child exit\n".utf8))
    pty.terminate()
}

// Read the screen on the same queue that wrote to it.
let screen = queue.sync { core.screenText() }

print("TERM=\(ShellEnvironment.term)  shell=\(ShellEnvironment.loginShell())")
print(String(repeating: "─", count: Int(size.columns)))
print(screen)
print(String(repeating: "─", count: Int(size.columns)))
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
let megabytes = Double(counter.total) / 1_048_576
print(String(
    format: "read %.1f MB in %d chunks over %.2fs (%.0f MB/s)",
    megabytes, counter.chunks, elapsed, elapsed > 0 ? megabytes / elapsed : 0
))
print("exit status: \(pty.reap(blocking: true).map(String.init) ?? "unknown")")

final class ByteCounter: @unchecked Sendable {
    private(set) var total = 0
    private(set) var chunks = 0
    func add(_ count: Int) { total += count; chunks += 1 }
}

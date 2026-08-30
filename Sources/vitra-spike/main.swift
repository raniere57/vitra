// vitra-spike -- headless diagnostics for the terminal core and renderer.
//
// Runs a command on a real pty, feeds every byte through the emulator, and
// reports the resulting screen. With --png it also renders that screen through
// the real Metal renderer, which makes the whole pipeline verifiable from a
// process that has no window and needs no screen-recording permission.
//
//   swift run vitra-spike                          # runs `ls -la`
//   swift run vitra-spike -- echo hi
//   swift run vitra-spike --png /tmp/out.png --size 60x12 -- ls -la

import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VitraCore
import VitraGhostty
import VitraRender
import Metal

struct Options {
    var command: [String] = ["/bin/ls", "-la"]
    var size = TerminalSize(columns: 80, rows: 24)
    var pngPath: String?
    var timeout: Double = 5

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--png" where index + 1 < arguments.count:
                options.pngPath = arguments[index + 1]
                index += 2
            case "--size" where index + 1 < arguments.count:
                let parts = arguments[index + 1].split(separator: "x").compactMap { UInt16($0) }
                if parts.count == 2 {
                    options.size = TerminalSize(columns: parts[0], rows: parts[1])
                }
                index += 2
            case "--timeout" where index + 1 < arguments.count:
                options.timeout = Double(arguments[index + 1]) ?? options.timeout
                index += 2
            case "--":
                rest.append(contentsOf: arguments[(index + 1)...])
                index = arguments.count
            default:
                rest.append(arguments[index])
                index += 1
            }
        }
        if !rest.isEmpty { options.command = rest }
        if let environmentTimeout = ProcessInfo.processInfo.environment["VITRA_SPIKE_TIMEOUT"],
           let value = Double(environmentTimeout) {
            options.timeout = value
        }
        return options
    }
}

final class ByteCounter: @unchecked Sendable {
    private(set) var total = 0
    private(set) var chunks = 0
    func add(_ count: Int) { total += count; chunks += 1 }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

let core = try GhosttyTerminalCore(size: options.size)
let pty = try PTY(
    executable: options.command[0],
    arguments: Array(options.command.dropFirst()),
    environment: ShellEnvironment.childEnvironment(),
    size: options.size
)

// libghostty requires serialized access to the terminal, so everything that
// touches the core -- feeding input and answering queries -- runs on this queue.
let queue = DispatchQueue(label: "dev.vitra.spike.session")

core.onWritePTY = { bytes in try? pty.write(bytes) }
core.onTitleChanged = { title in
    FileHandle.standardError.write(Data("[title] \(title)\n".utf8))
}

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

if finished.wait(timeout: .now() + options.timeout) == .timedOut {
    FileHandle.standardError.write(Data("[spike] timed out waiting for child exit\n".utf8))
    pty.terminate()
}

let screen = queue.sync { core.screenText() }

print("TERM=\(ShellEnvironment.term)  shell=\(ShellEnvironment.loginShell())")
print(String(repeating: "-", count: Int(options.size.columns)))
print(screen)
print(String(repeating: "-", count: Int(options.size.columns)))

let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
let megabytes = Double(counter.total) / 1_048_576
print(String(
    format: "read %.1f MB in %d chunks over %.2fs (%.0f MB/s)",
    megabytes, counter.chunks, elapsed, elapsed > 0 ? megabytes / elapsed : 0
))
print("exit status: \(pty.reap(blocking: true).map(String.init) ?? "unknown")")

if let path = options.pngPath {
    guard let device = MTLCreateSystemDefaultDevice() else {
        FileHandle.standardError.write(Data("[spike] no Metal device\n".utf8))
        exit(1)
    }
    let renderer = try TerminalRenderer(device: device, fonts: FontSet(name: "Menlo", size: 26))
    let snapshot = RenderSnapshot()
    _ = queue.sync { try? core.updateSnapshot(snapshot) }

    guard let image = renderer.renderImage(snapshot: snapshot, cursorOn: true, padding: 16),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          )
    else {
        FileHandle.standardError.write(Data("[spike] render failed\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(image.width)x\(image.height) png to \(path)")
}

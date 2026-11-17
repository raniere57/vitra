import Darwin
import Foundation
import Testing
@testable import VitraCore
@testable import VitraGhostty

/// A re-attached terminal redraws from the host's replay, and the replay
/// holds the queries the child once asked. A real emulator answers them; the
/// answers must not be typed into the child a second time.
@Test func aReplayedQueryIsDrawnButNotAnsweredAgain() throws {
    let short = String(UUID().uuidString.prefix(8))
    let paths = PTYHostPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vrq-\(short)", isDirectory: true))
    let host = PTYHost(paths: paths)
    try host.start()
    defer {
        host.stop()
        try? FileManager.default.removeItem(at: paths.directory)
    }

    func session() throws -> (TerminalSession, HostedPTY) {
        let spec = HostedPTY.Spec(
            id: "query",
            // Asks for the device attributes, then shows whatever it is sent.
            executable: "/bin/sh", arguments: ["-c", "printf 'asking\\033[c'; exec cat -v"],
            environment: ShellEnvironment.childEnvironment(), workingDirectory: NSTemporaryDirectory(), size: .default
        )
        let backend = HostedPTY(spec: spec, paths: paths, binary: nil)
        let terminal = TerminalSession(core: try GhosttyTerminalCore(size: .default), backend: backend, size: .default)
        terminal.start()
        return (terminal, backend)
    }
    func wait(_ terminal: TerminalSession, for needle: String) -> Bool {
        let deadline = Date() + 10
        while Date() < deadline, !terminal.screenText().contains(needle) { usleep(20_000) }
        return terminal.screenText().contains(needle)
    }
    func answers(_ text: String) -> Int { text.components(separatedBy: "[?").count - 1 }

    let (first, firstBackend) = try session()
    #expect(wait(first, for: "asking"))
    first.send(text: "MARK1\n")
    #expect(wait(first, for: "MARK1"))
    let answeredLive = answers(first.screenText())
    #expect(answeredLive > 0)
    first.detach()
    _ = firstBackend

    let (second, secondBackend) = try session()
    #expect(wait(second, for: "MARK1"))
    #expect(secondBackend.isInHost)
    second.send(text: "MARK2\n")
    #expect(wait(second, for: "MARK2"))
    #expect(answers(second.screenText()) == answeredLive)
    second.terminate()
}

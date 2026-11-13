import AppKit
import VitraBridge
import VitraCore

// `vitra mcp` is this same binary with no GUI: the agent's MCP client spawns it
// with its own stdin and stdout, and it forwards tool calls to the running
// window over the unix socket. AppKit is never touched on this path.
if CommandLine.arguments.dropFirst().first == "mcp" {
    StdioBridge.run()
    exit(0)
}

// `Vitra maestro-session` is the hook claude runs when the maestro's
// conversation starts or changes. It reads the session from stdin, notes it for
// the project, and says nothing: a SessionStart hook's output goes into the
// conversation.
if CommandLine.arguments.dropFirst().first == "maestro-session" {
    Maestro.recordSession(
        hookInput: FileHandle.standardInput.readDataToEndOfFile(),
        project: Maestro.tabFromEnvironment
    )
    exit(0)
}

// `Vitra hook <event>` is the hook claude runs when the maestro needs the user
// (Notification), ends a turn (Stop), is answered (UserPromptSubmit) or goes
// away (SessionEnd). It leaves the project's attention state on disk and says
// nothing; it always exits 0, so a hook can never get in claude's way.
if CommandLine.arguments.dropFirst().first == "hook" {
    Attention.run(
        event: CommandLine.arguments.dropFirst(2).first,
        input: FileHandle.standardInput.readDataToEndOfFile(),
        environmentProject: Maestro.tabFromEnvironment
    )
    exit(0)
}

// `Vitra maestro-status` is the maestro's status line: it notes the usage
// figures claude hands it, then runs the status line the user already had.
if CommandLine.arguments.dropFirst().first == "maestro-status" {
    Attention.resumed(project: Maestro.tabFromEnvironment)
    MaestroStatus.run(
        input: FileHandle.standardInput.readDataToEndOfFile(),
        binary: Bundle.main.executablePath ?? CommandLine.arguments[0]
    )
    exit(0)
}

// `Vitra pty-host` keeps the cockpit's project terminals alive across the app
// quitting and being reinstalled. The app starts it on demand, detached; it
// leaves by itself after ten idle minutes. AppKit is never touched on this path.
// VITRA_PTY_HOST_DIR moves its socket and lock elsewhere, for a test.
if CommandLine.arguments.dropFirst().first == "pty-host" {
    PTYHost.serveForever(paths: ProcessInfo.processInfo.environment["VITRA_PTY_HOST_DIR"]
        .map { PTYHostPaths(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? .standard)
}

// `Vitra snapshot <dir>` draws the cockpit's views offscreen, with made-up
// data, and writes PNGs. No window is shown and no Vitra needs to be running.
if CommandLine.arguments.dropFirst().first == "snapshot" {
    guard CommandLine.arguments.count == 3 else {
        FileHandle.standardError.write(Data("usage: Vitra snapshot <output-dir>\n".utf8))
        exit(2)
    }
    do {
        for file in try UISnapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[2])) { print(file.path) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}

// `VITRA_LEITURA_CHECK=1 Vitra leitura-check <file.jsonl>…`: the transcript
// reader over real files, printing only numbers. A developer's tool, so it
// answers only with the variable set.
if CommandLine.arguments.dropFirst().first == "leitura-check", ProcessInfo.processInfo.environment["VITRA_LEITURA_CHECK"] == "1" {
    MainActor.assumeIsolated { LeituraCheck.run(Array(CommandLine.arguments.dropFirst(2))) }
    exit(0)
}

// The cockpit is the app now. The classic terminal is still in the binary for
// whoever needs it, behind a flag, until nothing misses it.
let application = NSApplication.shared
let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--classic") ? AppDelegate() : CockpitAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.activate(ignoringOtherApps: true)
application.run()

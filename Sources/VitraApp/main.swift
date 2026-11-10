import AppKit
import VitraBridge

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
        project: ProcessInfo.processInfo.environment["VITRA_PROJECT"]
    )
    exit(0)
}

// `Vitra maestro-status` is the maestro's status line: it notes the usage
// figures claude hands it, then runs the status line the user already had.
if CommandLine.arguments.dropFirst().first == "maestro-status" {
    MaestroStatus.run(
        input: FileHandle.standardInput.readDataToEndOfFile(),
        binary: Bundle.main.executablePath ?? CommandLine.arguments[0]
    )
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

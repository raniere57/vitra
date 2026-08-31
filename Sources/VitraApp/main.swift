import AppKit
import VitraBridge

// `vitra mcp` is this same binary with no GUI: the agent's MCP client spawns it
// with its own stdin and stdout, and it forwards tool calls to the running
// window over the unix socket. AppKit is never touched on this path.
if CommandLine.arguments.dropFirst().first == "mcp" {
    StdioBridge.run()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.activate(ignoringOtherApps: true)
application.run()

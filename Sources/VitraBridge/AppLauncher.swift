import Foundation

/// Starts the app from the helper that lives inside it.
///
/// `vitra mcp` runs the app's own binary in a second, windowless process, so
/// the bundle is right there above it: `open` is asked for that exact copy
/// rather than for whatever a bundle identifier happens to resolve to today.
enum AppLauncher {
    /// Launches Vitra, at most once per process. True when something started.
    static func launch() -> Bool {
        guard !hasLaunched else { return true }
        hasLaunched = true

        guard open() else { return runDirectly() }
        // `open` returns as soon as it has handed the request to the system, so
        // the socket is what says the app is really coming up. Where the launch
        // is refused - a restricted session, an agent with no desktop - `open`
        // still exits zero and nothing happens, and the binary is run instead.
        return waitForSocket(Self.handoffTimeout) || runDirectly()
    }

    /// Asks the system to open the bundle, which is the right way when there is
    /// a desktop session to open it into.
    private static func open() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = bundle.map { ["-a", $0.path] } ?? ["-b", identifier]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs the app binary itself, for the times the system will not.
    private static func runDirectly() -> Bool {
        guard let executable = bundle?
            .appendingPathComponent("Contents/MacOS/Vitra") else { return false }
        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // This helper is spawned by an agent, and the app would otherwise
        // inherit the markers describing that agent's session.
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("CLAUDE_") && $0.key != "CLAUDECODE" && $0.key != "AI_AGENT" }
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func waitForSocket(_ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: SocketPath.path) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// How long the system is given to act on `open` before the binary is run.
    private static let handoffTimeout: TimeInterval = 5

    private static let identifier = "dev.vitra.Vitra"

    nonisolated(unsafe) private static var hasLaunched = false

    /// The bundle this helper is running out of, when it is running out of one.
    private static var bundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }
}

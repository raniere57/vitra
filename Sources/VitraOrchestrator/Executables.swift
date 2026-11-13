import Foundation

/// Where each worker CLI lives on this machine.
public struct Executables: Equatable, Sendable {
    public let paths: [WorkerCLI: String]

    public init(paths: [WorkerCLI: String]) {
        self.paths = paths
    }

    /// The CLI that ships inside OpenCode's desktop app.
    public static let openCodeAppCLI = "/Applications/OpenCode.app/Contents/Resources/opencode-cli"

    /// PATH, plus the places these CLIs install themselves: an MCP client often
    /// spawns its servers with a thinner PATH than the user's shell has.
    public static var defaultSearchPath: String {
        let home = NSHomeDirectory()
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let usual = ["\(home)/.local/bin", "\(home)/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return ([inherited] + usual).filter { !$0.isEmpty }.joined(separator: ":")
    }

    /// Finds the CLIs that are installed.
    ///
    /// For opencode the copy inside the desktop app wins when there is one. The
    /// app and the CLI share a database, the app migrates it to its own schema
    /// on launch, and a standalone CLI older than the app then refuses to open
    /// it ("Database is not empty and has no session table"). The copy in the
    /// app is the one that always matches.
    public static func discover(
        searchPath: String = defaultSearchPath,
        openCodeApp: String = openCodeAppCLI
    ) -> Executables {
        let directories = searchPath.split(separator: ":").map(String.init)
        let onPath = { (name: String) in
            directories.map { $0 + "/" + name }.first(where: FileManager.default.isExecutableFile(atPath:))
        }

        let found: [(WorkerCLI, String?)] = WorkerCLI.allCases.map { cli in
            let bundled = cli == .opencode && FileManager.default.isExecutableFile(atPath: openCodeApp)
            return (cli, bundled ? openCodeApp : onPath(cli.executableName))
        }
        return Executables(paths: found.reduce(into: [:]) { paths, entry in paths[entry.0] = entry.1 })
    }
}

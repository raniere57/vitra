import Darwin
import Foundation

/// Builds the environment and executable path for a terminal session's child process.
public enum ShellEnvironment {
    /// Terminal type Vitra advertises when the Ghostty terminfo entry is installed.
    public static let preferredTerm = "xterm-ghostty"
    /// Terminal type used otherwise. Every system has this entry.
    public static let fallbackTerm = "xterm-256color"

    /// The user's login shell.
    ///
    /// `SHELL` is checked first because it reflects what the user actually runs,
    /// then the passwd database, which is correct even when `SHELL` is unset or
    /// inherited from something odd.
    public static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty,
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    /// The terminal type to advertise, resolved once per process.
    ///
    /// `xterm-ghostty` unlocks the full feature set of the underlying engine, but
    /// claiming it without the terminfo entry installed leaves programs unable to
    /// look up any capability at all — far worse than the honest fallback.
    public static let term: String = {
        hasTerminfoEntry(preferredTerm) ? preferredTerm : fallbackTerm
    }()

    private static func hasTerminfoEntry(_ name: String) -> Bool {
        // infocmp knows every terminfo search path (system, $TERMINFO, ~/.terminfo)
        // and reimplementing that lookup would just get it subtly wrong.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        process.arguments = ["-x", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// The environment for a new session: the current one, minus variables that
    /// would lie to the child, plus Vitra's own.
    public static func childEnvironment(
        term: String = ShellEnvironment.term,
        shell: String? = nil,
        shellIntegration: Bool = true,
        blockSpacing: Bool = true,
        colorPrompt: Bool = true,
        colorDefaults: Bool = true,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // These describe the *parent* process. Left in place they make programs
        // adapt to a terminal that isn't the one they are talking to.
        for stale in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERMINFO", "COLUMNS", "LINES"] {
            env.removeValue(forKey: stale)
        }

        env["TERM"] = term
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "vitra"
        env["TERM_PROGRAM_VERSION"] = Vitra.version

        // BSD tools ship colourless: `ls` on macOS prints the same grey for a
        // directory, a symlink and an executable unless CLICOLOR says otherwise.
        // Only set when the user has not already decided.
        if colorDefaults, env["CLICOLOR"] == nil { env["CLICOLOR"] = "1" }

        // Before `extra`, so an explicit override still wins.
        if shellIntegration {
            let path = shell ?? loginShell()
            for (key, value) in ShellIntegration.environment(
                shell: path,
                current: env,
                blockSpacing: blockSpacing,
                colorPrompt: colorPrompt
            ) {
                env[key] = value
            }
        }

        for (key, value) in extra { env[key] = value }
        return env
    }
}

public enum Vitra {
    public static let version = "0.1.0"

    /// `~/.vitra`, created on demand.
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vitra", isDirectory: true)
    }
}

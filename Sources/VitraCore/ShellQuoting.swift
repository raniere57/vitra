import Foundation

/// Quoting for file paths that are typed into a prompt.
///
/// Attachments reach the agent as text on a command line, so a path with a
/// space, a quote, or a glob character has to survive being read back. Getting
/// this wrong does not produce a broken path — it produces a *different* path,
/// or a shell that runs part of it.
public enum ShellQuoting {
    /// Characters that never need quoting in any POSIX shell.
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-@%+=:,")

    /// Quotes `path` if it needs it, leaving simple paths untouched.
    ///
    /// Single quotes rather than double: inside single quotes a POSIX shell
    /// expands nothing at all, so `$HOME`, backticks, and backslashes in a
    /// filename stay literal.
    public static func quote(_ path: String) -> String {
        guard !path.isEmpty else { return "''" }
        guard path.contains(where: { !safe.contains($0) }) else { return path }
        // A single quote cannot appear inside single quotes, so the string is
        // closed, an escaped quote is emitted, and the string reopens.
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Joins paths into one space-separated, individually quoted argument list.
    public static func join(_ paths: [String]) -> String {
        paths.map(quote).joined(separator: " ")
    }
}

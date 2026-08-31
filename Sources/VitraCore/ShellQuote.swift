import Foundation

/// Quotes a path for a shell that is about to be typed at.
///
/// The sidebars change directory by writing `cd …` into the terminal, which is
/// exactly as if the user had typed it — so a folder called `it's a "test"`
/// has to survive the trip.
public enum ShellQuote {
    /// The path as a single shell word.
    ///
    /// Single quotes take everything literally, and the only character they
    /// cannot carry is the single quote itself: it is closed, escaped and
    /// reopened, which is what every shell expects.
    public static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The line that changes directory, newline included.
    public static func changeDirectory(to path: String) -> String {
        "cd " + quote(path) + "\n"
    }
}

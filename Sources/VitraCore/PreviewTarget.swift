import Foundation

/// A file the panel has been asked to show.
///
/// Every path that reaches the preview — from the escape sequence, the CLI, or
/// later the MCP server — is turned into one of these first. Resolution is
/// deliberately strict: the panel only ever opens a regular file that already
/// exists, so a request cannot be used to probe the filesystem or to make the
/// app open something that is not a file at all.
public struct PreviewTarget: Sendable, Equatable {
    public let url: URL

    public var displayName: String { url.lastPathComponent }

    private init(url: URL) { self.url = url }

    /// Resolves `path` against `base`, or nil when it is not a readable file.
    ///
    /// `~` is expanded, relative paths are taken against `base` (the shell's
    /// working directory when it is known), symlinks are followed, and the
    /// result must be an existing regular file. Directories, devices, sockets
    /// and dangling links are all rejected.
    public static func resolve(path: String, relativeTo base: URL? = nil) -> PreviewTarget? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else if let base {
            // absoluteURL, because a relative URL carries its base around and
            // resource lookups on it answer for the wrong path.
            // isDirectory: true matters — Foundation no longer inspects the
            // filesystem, so a base without a trailing slash has its last
            // component replaced instead of appended to.
            let directory = URL(fileURLWithPath: base.path, isDirectory: true)
            candidate = URL(fileURLWithPath: expanded, relativeTo: directory).absoluteURL
        } else {
            // Without a working directory to resolve against, a bare name is
            // ambiguous; the app's own cwd is not what the user meant.
            return nil
        }

        // resolvingSymlinksInPath() also standardises `..`, which is what keeps
        // a path from pointing somewhere its text does not say.
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }

        return PreviewTarget(url: resolved)
    }

    /// Reads the `file=<path>` payload of an `ESC ] 7337` sequence.
    ///
    /// Unknown keys are ignored rather than treated as an error: the sequence is
    /// meant to grow, and an older build should skip what it does not know.
    public static func parse(payload: String, relativeTo base: URL? = nil) -> PreviewTarget? {
        for field in payload.split(separator: ";") {
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = field[field.startIndex..<separator]
            guard key == "file" else { continue }
            return resolve(path: String(field[field.index(after: separator)...]), relativeTo: base)
        }
        return nil
    }
}

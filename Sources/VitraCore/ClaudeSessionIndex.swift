import Foundation

/// What the Claude desktop app knows about a session that the transcript does
/// not: the name the user gave it, and whether they archived it.
///
/// The app keeps one small JSON per session beside its own data; the transcript
/// in `~/.claude/projects` carries no archive flag at all. Without this, a
/// sidebar reading only transcripts shows every session the user has already
/// put away.
public struct SessionIndexEntry: Sendable, Equatable {
    public let title: String?
    public let isArchived: Bool

    public init(title: String?, isArchived: Bool) {
        self.title = title
        self.isArchived = isArchived
    }
}

public enum ClaudeSessionIndex {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// The index, keyed by the session id the transcripts use.
    ///
    /// The app files are nested one organisation and one account deep and named
    /// after its own id, so the mapping runs through `cliSessionId`. A missing
    /// or unreadable index is not an error: it means the app was never used
    /// here, and every transcript is simply shown.
    public static func load(from directory: URL = ClaudeSessionIndex.directory) -> [String: SessionIndexEntry] {
        var entries: [String: SessionIndexEntry] = [:]
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return entries }

        for case let url as URL in walker {
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("local_") else { continue }
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["cliSessionId"] as? String, !id.isEmpty
            else { continue }

            let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            entries[id] = SessionIndexEntry(
                title: title,
                isArchived: object["isArchived"] as? Bool ?? false
            )
        }
        return entries
    }
}

import Foundation
import SQLite3

/// Reads opencode's session store.
///
/// opencode keeps its conversations in one SQLite file rather than a directory
/// of transcripts, so this asks for the columns the sidebar draws and nothing
/// else: no message is read, and the database is opened read-only and closed
/// again on every listing, because opencode is writing to it while we look.
public enum OpenCodeSessionStore {
    public static var databasePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
    }

    /// The most recently touched sessions, newest first.
    ///
    /// Children are left out: a subagent's conversation is part of the session
    /// that started it, not a row of its own.
    public static func recent(
        limit: Int = 80,
        at path: URL = OpenCodeSessionStore.databasePath,
        includeArchived: Bool = false
    ) -> AgentSession.Listing {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return AgentSession.Listing(sessions: [], archivedHidden: 0)
        }
        guard let database = open(path) else {
            return AgentSession.Listing(sessions: [], archivedHidden: 0)
        }
        defer { sqlite3_close(database) }

        let sql = """
        select id, directory, title, time_updated, time_archived
        from session
        where parent_id is null
        order by time_updated desc
        limit ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return .empty }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var all: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let directory = text(statement, 1) else { continue }
            let title = text(statement, 2) ?? ""
            // Milliseconds, which is what opencode writes.
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
            let archived = sqlite3_column_type(statement, 4) != SQLITE_NULL
            all.append(
                AgentSession(
                    id: id,
                    title: name(title, in: directory),
                    projectPath: directory,
                    modified: updated,
                    isArchived: archived,
                    harness: .openCode
                )
            )
        }

        return AgentSession.Listing(
            sessions: includeArchived ? all : all.filter { !$0.isArchived },
            archivedHidden: all.filter(\.isArchived).count
        )
    }

    /// A session opencode has not named yet is called after its folder: the
    /// stamp it writes instead — `New session - 2026-08-31T19:40:12.348Z` — is
    /// the date the row already carries, spelled twice.
    private static func name(_ title: String, in directory: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed.hasPrefix("New session") else { return trimmed }
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        return folder.isEmpty ? "New session" : "New session in \(folder)"
    }

    /// Read-only, and read-only twice over: `immutable` is the fallback for a
    /// database whose write-ahead log this process may not touch, and a stale
    /// row is a better answer than an empty sidebar.
    private static func open(_ path: URL) -> OpaquePointer? {
        var database: OpaquePointer?
        let readOnly = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let escaped = path.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path.path
        if sqlite3_open_v2("file:\(escaped)?mode=ro", &database, readOnly, nil) == SQLITE_OK,
           probe(database) {
            return database
        }
        sqlite3_close(database)
        database = nil
        guard sqlite3_open_v2("file:\(escaped)?immutable=1", &database, readOnly, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    /// Whether the handle can actually read the table, which an open alone does
    /// not say: a locked or unreadable database fails at the first statement.
    private static func probe(_ database: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "select 1 from session limit 1", -1, &statement, nil) == SQLITE_OK
        else { return false }
        let step = sqlite3_step(statement)
        return step == SQLITE_ROW || step == SQLITE_DONE
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }
}

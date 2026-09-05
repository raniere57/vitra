import Foundation
import SQLite3

/// Reads Codex's session index.
///
/// Codex writes each conversation as a rollout `.jsonl` under
/// `~/.codex/sessions/`, and keeps an index of them in a SQLite file whose name
/// carries a schema version — `state_5.sqlite` today. The index is what the
/// sidebar needs: id, folder, title, when. Opened read-only and closed again on
/// every listing, because Codex is writing to it while we look.
public enum CodexSessionStore {
    /// The newest `state_*.sqlite` in `~/.codex`: the version in the name goes
    /// up with the schema, and the highest one is the one Codex is using.
    public static var databasePath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let newest = candidates
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .sorted { lhs, rhs in
                lhs.compare(rhs, options: .numeric) == .orderedAscending
            }
            .last ?? "state_5.sqlite"
        return home.appendingPathComponent(newest, isDirectory: false)
    }

    /// The most recently touched sessions, newest first.
    public static func recent(
        limit: Int = 80,
        at path: URL = CodexSessionStore.databasePath,
        includeArchived: Bool = false
    ) -> AgentSession.Listing {
        guard FileManager.default.fileExists(atPath: path.path), let database = open(path) else {
            return .empty
        }
        defer { sqlite3_close(database) }

        let sql = """
        select id, cwd, title, name, first_user_message, updated_at, archived
        from threads
        order by updated_at desc
        limit ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return .empty }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var all: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let directory = text(statement, 1) else { continue }
            let title = name(
                text(statement, 3), text(statement, 2), text(statement, 4),
                in: directory
            )
            // Seconds, which is what Codex writes in updated_at.
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)))
            let archived = sqlite3_column_int64(statement, 6) != 0
            all.append(
                AgentSession(
                    id: id,
                    title: title,
                    projectPath: directory,
                    modified: updated,
                    isArchived: archived,
                    harness: .codex
                )
            )
        }

        return AgentSession.Listing(
            sessions: includeArchived ? all : all.filter { !$0.isArchived },
            archivedHidden: all.filter(\.isArchived).count
        )
    }

    /// What to call a session: the name the user gave it, else the title Codex
    /// wrote, else the first line of the first message, else its folder. A
    /// title that is a whole first message is cut to a line.
    private static func name(_ given: String?, _ title: String?, _ first: String?, in directory: String) -> String {
        for candidate in [given, title, first] {
            guard let candidate else { continue }
            let line = candidate
                .split(whereSeparator: \.isNewline)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            return line.count > 72 ? String(line.prefix(71)) + "…" : line
        }
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        return folder.isEmpty ? "New session" : "New session in \(folder)"
    }

    /// Read-only, and read-only twice over: `immutable` is the fallback for a
    /// database whose write-ahead log this process may not touch.
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

    private static func probe(_ database: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "select 1 from threads limit 1", -1, &statement, nil) == SQLITE_OK
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

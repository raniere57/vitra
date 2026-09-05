import Foundation
import SQLite3
import Testing
@testable import VitraCore

/// The columns the store reads, in the shape Codex's `threads` table has them.
private func database(_ rows: [(id: String, cwd: String, title: String, name: String?, first: String, updated: Int64, archived: Int64)]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-codex-\(UUID().uuidString).sqlite")
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    let schema = """
    create table threads (
      id text primary key, cwd text not null, title text not null default '',
      name text, first_user_message text not null default '',
      updated_at integer not null, archived integer not null default 0
    );
    """
    #expect(sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK)
    for row in rows {
        let name = row.name.map { "'\($0)'" } ?? "null"
        let insert = """
        insert into threads values ('\(row.id)', '\(row.cwd)', '\(row.title)', \(name),
          '\(row.first)', \(row.updated), \(row.archived));
        """
        #expect(sqlite3_exec(handle, insert, nil, nil, nil) == SQLITE_OK)
    }
    return url
}

@Test("Codex sessions come back newest first, with a resume line")
func codexSessionsAreListed() throws {
    let path = try database([
        (id: "t-a", cwd: "/Users/x/Dev/farol", title: "Investigar erro", name: nil, first: "", updated: 2_000, archived: 0),
        (id: "t-b", cwd: "/Users/x/Dev/vitra", title: "Corrigir topbar", name: nil, first: "", updated: 3_000, archived: 0),
    ])
    let listing = CodexSessionStore.recent(at: path)
    #expect(listing.sessions.map(\.id) == ["t-b", "t-a"])
    #expect(listing.sessions.allSatisfy { $0.harness == .codex })
    #expect(listing.sessions.first?.modified == Date(timeIntervalSince1970: 3_000))
    #expect(listing.sessions.first?.resumeCommand == "cd '/Users/x/Dev/vitra' && codex resume t-b\n")
}

@Test("a name the user gave wins; a first message stands in for a missing title")
func codexTitlesFallBackInOrder() throws {
    let path = try database([
        (id: "t-a", cwd: "/Users/x/Dev/a", title: "Written title", name: "My name", first: "hello", updated: 3, archived: 0),
        (id: "t-b", cwd: "/Users/x/Dev/b", title: "", name: nil, first: "first line here\nsecond line", updated: 2, archived: 0),
        (id: "t-c", cwd: "/Users/x/Dev/c", title: "", name: nil, first: "", updated: 1, archived: 0),
    ])
    let titles = CodexSessionStore.recent(at: path).sessions.map(\.title)
    #expect(titles == ["My name", "first line here", "New session in c"])
}

@Test("archived Codex sessions are counted and dropped")
func codexArchivedAreHidden() throws {
    let path = try database([
        (id: "t-a", cwd: "/Users/x/Dev/a", title: "Live", name: nil, first: "", updated: 2, archived: 0),
        (id: "t-b", cwd: "/Users/x/Dev/a", title: "Old", name: nil, first: "", updated: 3, archived: 1),
    ])
    let listing = CodexSessionStore.recent(at: path)
    #expect(listing.sessions.map(\.id) == ["t-a"])
    #expect(listing.archivedHidden == 1)
}

@Test("no Codex database is an empty list")
func codexMissingDatabaseIsEmpty() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope-\(UUID().uuidString).sqlite")
    #expect(CodexSessionStore.recent(at: missing).sessions.isEmpty)
}

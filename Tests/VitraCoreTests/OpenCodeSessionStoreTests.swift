import Foundation
import SQLite3
import Testing
@testable import VitraCore

/// Writes the columns the store reads, in the shape opencode writes them.
private func database(_ rows: [(id: String, parent: String?, directory: String, title: String, updated: Int64, archived: Int64?)]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-opencode-\(UUID().uuidString).db")
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    let schema = """
    create table session (
      id text primary key, project_id text, parent_id text, slug text,
      directory text not null, title text not null,
      time_updated integer not null, time_archived integer
    );
    """
    #expect(sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK)
    for row in rows {
        let parent = row.parent.map { "'\($0)'" } ?? "null"
        let archived = row.archived.map(String.init) ?? "null"
        let insert = """
        insert into session values ('\(row.id)', 'p', \(parent), 'slug',
          '\(row.directory)', '\(row.title)', \(row.updated), \(archived));
        """
        #expect(sqlite3_exec(handle, insert, nil, nil, nil) == SQLITE_OK)
    }
    return url
}

@Test("sessions come back newest first, without the subagents")
func openCodeSessionsAreListed() throws {
    let path = try database([
        (id: "ses_a", parent: nil, directory: "/Users/x/Dev/farol", title: "Refactor the parser", updated: 2_000, archived: nil),
        (id: "ses_b", parent: nil, directory: "/Users/x/Dev/vitra", title: "Ship the panel", updated: 3_000, archived: nil),
        (id: "ses_child", parent: "ses_b", directory: "/Users/x/Dev/vitra", title: "subagent", updated: 4_000, archived: nil),
    ])
    let listing = OpenCodeSessionStore.recent(at: path)
    #expect(listing.sessions.map(\.id) == ["ses_b", "ses_a"])
    #expect(listing.sessions.allSatisfy { $0.harness == .openCode })
    #expect(listing.sessions.first?.projectName == "vitra")
    #expect(listing.sessions.first?.modified == Date(timeIntervalSince1970: 3))
    #expect(listing.sessions.first?.resumeCommand == "cd '/Users/x/Dev/vitra' && opencode --session ses_b\n")
}

@Test("an archived session is counted and dropped")
func archivedSessionsAreHidden() throws {
    let path = try database([
        (id: "ses_a", parent: nil, directory: "/Users/x/Dev/farol", title: "Live one", updated: 2_000, archived: nil),
        (id: "ses_b", parent: nil, directory: "/Users/x/Dev/farol", title: "Put away", updated: 3_000, archived: 9_000),
    ])
    let listing = OpenCodeSessionStore.recent(at: path)
    #expect(listing.sessions.map(\.id) == ["ses_a"])
    #expect(listing.archivedHidden == 1)
    #expect(OpenCodeSessionStore.recent(at: path, includeArchived: true).sessions.count == 2)
}

@Test("a session opencode never named is called after its folder")
func unnamedSessionsAreNamedAfterTheFolder() throws {
    let path = try database([
        (id: "ses_a", parent: nil, directory: "/Users/x/Dev/vitra", title: "New session - 2026-08-31T19:40:12.348Z", updated: 1, archived: nil),
    ])
    #expect(OpenCodeSessionStore.recent(at: path).sessions.first?.title == "New session in vitra")
}

@Test("no database is an empty list, not a crash")
func missingDatabaseIsEmpty() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope-\(UUID().uuidString).db")
    #expect(OpenCodeSessionStore.recent(at: missing).sessions.isEmpty)
}

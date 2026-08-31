import Foundation
import Testing
@testable import VitraCore

/// Writes a transcript the way Claude Code writes one: one JSON object a line.
private func writeSession(
    in store: URL,
    project: String,
    id: String,
    lines: [[String: Any]],
    modified: Date? = nil
) throws -> URL {
    let directory = store.appendingPathComponent(project)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(id).jsonl")

    let text = try lines
        .map { try String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8) ?? "" }
        .joined(separator: "\n")
    try Data(text.utf8).write(to: file)

    if let modified {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }
    return file
}

private func makeStore() throws -> URL {
    let store = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitra-sessions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    return store
}

@Test func aNamedSessionIsListedUnderItsCurrentTitle() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    _ = try writeSession(
        in: store,
        project: "-Users-me-Dev-farol",
        id: "aaa",
        lines: [
            ["type": "user", "cwd": "/Users/me/Dev/farol", "message": ["content": "olá"]],
            ["type": "custom-title", "customTitle": "First name"],
            ["type": "custom-title", "customTitle": "Renamed later"],
        ]
    )

    let sessions = ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions

    #expect(sessions.count == 1)
    #expect(sessions[0].title == "Renamed later")
    #expect(sessions[0].id == "aaa")
    #expect(sessions[0].projectPath == "/Users/me/Dev/farol")
    #expect(sessions[0].projectName == "farol")
}

@Test func anUnnamedSessionFallsBackToWhatWasAsked() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    _ = try writeSession(
        in: store,
        project: "-Users-me-Dev-mac",
        id: "bbb",
        lines: [
            ["type": "user", "cwd": "/Users/me/Dev/mac", "message": ["content": [["type": "text", "text": "fix the build"]]]],
        ]
    )

    #expect(ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions.first?.title == "fix the build")
}

@Test func sessionsAreListedNewestFirst() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    let now = Date()
    _ = try writeSession(
        in: store,
        project: "-Users-me-a",
        id: "old",
        lines: [["type": "user", "cwd": "/Users/me/a", "message": ["content": "old"]]],
        modified: now.addingTimeInterval(-3600)
    )
    _ = try writeSession(
        in: store,
        project: "-Users-me-b",
        id: "new",
        lines: [["type": "user", "cwd": "/Users/me/b", "message": ["content": "new"]]],
        modified: now
    )

    #expect(ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions.map(\.id) == ["new", "old"])
}

@Test func aTranscriptWithoutAWorkingDirectoryIsSkipped() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    _ = try writeSession(
        in: store,
        project: "-Users-me-c",
        id: "ccc",
        lines: [["type": "queue-operation", "timestamp": "2026-08-18T20:00:05.331Z"]]
    )

    #expect(ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions.isEmpty)
}

@Test func resumingCarriesTheDirectoryTheSessionBelongsTo() {
    let session = ClaudeSession(
        id: "a680e56f",
        title: "Report",
        projectPath: "/Users/me/Dev/it's here",
        modified: Date()
    )

    #expect(
        ClaudeSessionStore.resumeCommand(for: session)
            == "cd '/Users/me/Dev/it'\\''s here' && claude --resume a680e56f\n"
    )
}

@Test func aTitleLongerThanARowIsCutToOne() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    _ = try writeSession(
        in: store,
        project: "-Users-me-d",
        id: "ddd",
        lines: [
            ["type": "user", "cwd": "/Users/me/d", "message": ["content": "x"]],
            ["type": "custom-title", "customTitle": String(repeating: "a", count: 200)],
        ]
    )

    let title = try #require(ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions.first?.title)
    #expect(title.count == 80)
    #expect(title.hasSuffix("…"))
}

@Test func promptMachineryDoesNotBecomeATitle() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    _ = try writeSession(
        in: store,
        project: "-Users-me-e",
        id: "eee",
        lines: [
            [
                "type": "user",
                "cwd": "/Users/me/e",
                "message": ["content": "<local-command-caveat>Caveat: the messages below…</local-command-caveat>"],
            ],
            ["type": "user", "message": ["content": "[Image: source: /Users/me/shot.png] arruma o gráfico"]],
        ]
    )

    #expect(ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions.first?.title == "arruma o gráfico")
}

@Test func aSessionThatIsOnlyASlashCommandIsNamedAfterIt() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    _ = try writeSession(
        in: store,
        project: "-Users-me-f",
        id: "fff",
        lines: [
            [
                "type": "user",
                "cwd": "/Users/me/f",
                "message": ["content": "<local-command-caveat>Caveat: …</local-command-caveat>"],
            ],
            [
                "type": "user",
                "message": ["content": "<command-message>sessions</command-message> <command-name>/sessions</command-name>"],
            ],
        ]
    )

    #expect(ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions.first?.title == "/sessions")
}

@Test func aWorktreeSessionBelongsToItsProject() {
    let session = ClaudeSession(
        id: "ggg",
        title: "Corrigir README",
        projectPath: "/Users/me/Dev/farol/.claude/worktrees/charming-noyce-e37669",
        modified: Date()
    )

    #expect(session.projectName == "farol")
    #expect(session.worktree == "charming-noyce-e37669")
}

@Test func aPlainSessionHasNoWorktree() {
    let session = ClaudeSession(id: "hhh", title: "x", projectPath: "/Users/me/Dev/farol", modified: Date())

    #expect(session.projectName == "farol")
    #expect(session.worktree == nil)
}

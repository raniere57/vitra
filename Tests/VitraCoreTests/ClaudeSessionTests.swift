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
    let session = AgentSession(
        id: "a680e56f",
        title: "Report",
        projectPath: "/Users/me/Dev/it's here",
        modified: Date()
    )

    #expect(
        session.resumeCommand
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
    let session = AgentSession(
        id: "ggg",
        title: "Corrigir README",
        projectPath: "/Users/me/Dev/farol/.claude/worktrees/charming-noyce-e37669",
        modified: Date()
    )

    #expect(session.projectName == "farol")
    #expect(session.worktree == "charming-noyce-e37669")
}

@Test func aPlainSessionHasNoWorktree() {
    let session = AgentSession(id: "hhh", title: "x", projectPath: "/Users/me/Dev/farol", modified: Date())

    #expect(session.projectName == "farol")
    #expect(session.worktree == nil)
}

/// Writes the little JSON the desktop app keeps beside each session.
private func writeIndexEntry(
    in store: URL,
    cliSessionId: String,
    title: String? = nil,
    isArchived: Bool = false,
    priorCliSessionIds: [String] = []
) throws {
    var object: [String: Any] = [
        "cliSessionId": cliSessionId,
        "isArchived": isArchived,
        "priorCliSessionIds": priorCliSessionIds,
    ]
    if let title { object["title"] = title }
    try JSONSerialization.data(withJSONObject: object)
        .write(to: store.appendingPathComponent("local_\(cliSessionId).json"))
}

@Test func aSupersededSegmentIsNotListedBesideTheSessionThatReplacedIt() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    let now = Date()
    _ = try writeSession(
        in: store,
        project: "-Users-me-Dev-farol",
        id: "before-compaction",
        lines: [["type": "user", "cwd": "/Users/me/Dev/farol", "message": ["content": "começa aqui"]]],
        modified: now.addingTimeInterval(-3600)
    )
    _ = try writeSession(
        in: store,
        project: "-Users-me-Dev-farol",
        id: "still-running",
        lines: [["type": "user", "cwd": "/Users/me/Dev/farol", "message": ["content": "continua"]]],
        modified: now
    )
    try writeIndexEntry(
        in: store,
        cliSessionId: "still-running",
        title: "Farol",
        priorCliSessionIds: ["before-compaction"]
    )

    let sessions = ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions

    #expect(sessions.map(\.id) == ["still-running"])
}

@Test func whatACompactionLeftBehindIsNotListedAsASession() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    _ = try writeSession(
        in: store,
        project: "-Users-me-Dev-farol",
        id: "fragment",
        lines: [
            [
                "type": "user",
                "cwd": "/Users/me/Dev/farol",
                "message": ["content": "This session is being continued from a previous conversation that ran out of context."],
            ],
        ]
    )

    #expect(ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions.isEmpty)
}

@Test func theSameConversationResumedTwiceIsListedOnce() throws {
    let store = try makeStore()
    defer { try? FileManager.default.removeItem(at: store) }
    let now = Date()
    for (id, age) in [("first-run", -7200.0), ("resumed", 0.0)] {
        _ = try writeSession(
            in: store,
            project: "-Users-me-Dev-farol",
            id: id,
            lines: [["type": "user", "cwd": "/Users/me/Dev/farol", "message": ["content": "arruma o importador"]]],
            modified: now.addingTimeInterval(age)
        )
    }

    let sessions = ClaudeSessionStore.recent(in: store, indexDirectory: store).sessions

    #expect(sessions.map(\.id) == ["resumed"])
}

@Test func aTerminalIsMatchedToTheSessionItIsNamedAfter() {
    let now = Date()
    let sessions = [
        AgentSession(
            id: "old", title: "Marketing", projectPath: "/Users/x/farol",
            modified: now.addingTimeInterval(-3600), isArchived: false
        ),
        AgentSession(
            id: "new", title: "Marketing", projectPath: "/Users/x/farol",
            modified: now, isArchived: false
        ),
        AgentSession(
            id: "other", title: "Marketing", projectPath: "/Users/x/vitra",
            modified: now, isArchived: false
        ),
    ]

    // Claude Code decorates the title with a status glyph; the letters are what
    // is compared, and the newest of a project's namesakes wins.
    #expect(
        ClaudeSessionStore.matching(title: "✳ Marketing", directory: "/Users/x/farol", in: sessions)?.id
            == "new"
    )
    // The other project keeps its own session of the same name.
    #expect(
        ClaudeSessionStore.matching(title: "Marketing", directory: "/Users/x/vitra", in: sessions)?.id
            == "other"
    )
    // A worktree is inside the project it belongs to.
    #expect(
        ClaudeSessionStore.matching(
            title: "Marketing",
            directory: "/Users/x/farol/.claude/worktrees/eager-lamport",
            in: sessions
        )?.id == "new"
    )
    #expect(ClaudeSessionStore.matching(title: "Marketing", directory: "/tmp", in: sessions) == nil)
    // A title too short to be a name matches nothing at all.
    #expect(ClaudeSessionStore.matching(title: "ok", directory: nil, in: sessions) == nil)
}

@Test func aTitleCutShortStillFindsItsSession() {
    let sessions = [
        AgentSession(
            id: "long", title: "Vitra: macOS terminal emulator", projectPath: "/Users/x/vitra",
            modified: Date(), isArchived: false
        ),
    ]

    // The terminal gets the summary cut short; the transcript keeps it whole.
    #expect(
        ClaudeSessionStore.matching(
            title: "✳ Vitra: macOS terminal emu",
            directory: "/Users/x/vitra",
            in: sessions
        )?.id == "long"
    )
    // Eight letters of overlap is the floor: "Vitra" alone is a coincidence.
    #expect(
        ClaudeSessionStore.matching(title: "Vitra", directory: "/Users/x/vitra", in: sessions) == nil
    )
}

@Test func claudeCodesOwnMarkerFallsBackToTheProjectsNewest() {
    let now = Date()
    let sessions = [
        AgentSession(
            id: "newest", title: "Something else entirely", projectPath: "/Users/x/farol",
            modified: now, isArchived: false
        ),
        AgentSession(
            id: "older", title: "Older still", projectPath: "/Users/x/farol",
            modified: now.addingTimeInterval(-60), isArchived: false
        ),
    ]

    // A summary the sidebar has not caught up with yet: the ✳ says Claude Code
    // is what is running, and the project's newest session is the only one it
    // can reasonably be.
    #expect(
        ClaudeSessionStore.matching(title: "✳ A brand new summary", directory: "/Users/x/farol", in: sessions)?.id
            == "newest"
    )
    // Without the marker, a pane running something else marks nothing.
    #expect(
        ClaudeSessionStore.matching(title: "vim README.md", directory: "/Users/x/farol", in: sessions) == nil
    )
    // And never outside the project.
    #expect(
        ClaudeSessionStore.matching(title: "✳ Anything", directory: "/tmp", in: sessions) == nil
    )
}

import Foundation
import Testing
@testable import VitraApp

@Test func aTabIsToldWhatTheOtherTabsOfItsFolderDidAndOnlyOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    ProjectJournal.append(.init(time: now.addingTimeInterval(-60), session: "s2", tab: "hapto 2", prompt: "Arruma o login", answer: "Arrumei", commits: ["abc123 fix: login"]), for: "/w/hapto#2", in: directory)
    ProjectJournal.append(.init(time: now.addingTimeInterval(-30), session: "s1", tab: "hapto", prompt: "meu próprio", answer: "x", commits: []), for: "/w/hapto", in: directory)

    let input = Data(#"{"session_id":"s1","cwd":"/w/hapto","hook_event_name":"UserPromptSubmit"}"#.utf8)
    let news = try #require(ProjectJournal.hook(event: "UserPromptSubmit", input: input, tab: "/w/hapto", in: directory, now: now))
    #expect(news.contains("aba hapto 2 · pediu: Arruma o login") && news.contains("abc123 fix: login"))
    #expect(!news.contains("meu próprio"))
    #expect(ProjectJournal.hook(event: "UserPromptSubmit", input: input, tab: "/w/hapto", in: directory, now: now.addingTimeInterval(5)) == nil)
    // Another folder's diary is its own.
    #expect(ProjectJournal.file(for: "/w/hapto#3", in: directory) == ProjectJournal.file(for: "/w/hapto", in: directory))
    #expect(ProjectJournal.file(for: "/w/efetivy", in: directory) != ProjectJournal.file(for: "/w/hapto", in: directory))
}

@Test func theTurnThatEndedIsReadFromTheConversationsEnd() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    let lines = [
        #"{"type":"user","timestamp":"2026-11-15T10:00:00.000Z","message":{"role":"user","content":"Cria a aba Tração"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-15T10:00:05.000Z","message":{"content":[{"type":"text","text":"Vou olhar."}]}}"#,
        #"{"type":"user","timestamp":"2026-11-15T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-11-15T10:01:00.000Z","message":{"content":[{"type":"text","text":"Aba criada e publicada."}]}}"#,
    ]
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
    let turn = try #require(ProjectJournal.lastTurn(in: url))
    #expect(turn.prompt == "Cria a aba Tração" && turn.answer == "Aba criada e publicada.")
}

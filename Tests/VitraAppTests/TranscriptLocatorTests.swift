import Foundation
import Testing
@testable import VitraApp

@Test func aModelIdReadsAsClaudeNamesIt() {
    #expect(TranscriptLocator.displayName("claude-fable-5-2") == "Fable 5.2")
    #expect(TranscriptLocator.displayName("claude-opus-5-5") == "Opus 5.5")
    #expect(TranscriptLocator.displayName("claude-haiku-5-5-20261001") == "Haiku 5.5")
}

@Test func aConversationStartedInAWorktreeIsFoundAndItsModelRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-locator-\(UUID().uuidString)")
    let worktree = root.appendingPathComponent("-proj--claude-worktrees-x")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = worktree.appendingPathComponent("s1.jsonl")
    try """
    {"type":"assistant","message":{"model":"claude-opus-5-5"}}
    {"type":"assistant","message":{"model":"claude-fable-5-2"}}

    """.write(to: file, atomically: true, encoding: .utf8)
    let url = TranscriptLocator.url(project: "/proj", session: "s1", root: root)
    #expect(url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    #expect(TranscriptLocator.lastModel(in: url) == "Fable 5.2")
    #expect(TranscriptLocator.url(project: "/proj", session: "s2", root: root).deletingLastPathComponent().lastPathComponent == "-proj")
}

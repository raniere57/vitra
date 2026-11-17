import Foundation
import Testing
@testable import VitraApp

@Test func slashMatchesPutNamesStartingWithTheQueryFirst() {
    let all = ["/clear", "/compact", "/caveman:compress", "/model"].map { ComposerCompletion(insert: $0, detail: "") }
    #expect(SlashCatalog.matching("comp", in: all).map(\.insert) == ["/compact", "/caveman:compress"])
    #expect(SlashCatalog.matching("", in: all).count == 4)
    #expect(SlashCatalog.matching("xyz", in: all).isEmpty)
}

@Test func onlyABareInteractiveCommandOpensAScreen() {
    #expect(SlashCatalog.opensScreen("/model"))
    #expect(SlashCatalog.opensScreen("/resume\n"))
    #expect(!SlashCatalog.opensScreen("/model opus"))
    #expect(!SlashCatalog.opensScreen("/clear"))
    #expect(!SlashCatalog.opensScreen("olha o /model"))
}

@Test func slashCatalogReadsTheUsersCommandsAndSkills() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let commands = home.appendingPathComponent(".claude/commands/git")
    let skill = home.appendingPathComponent(".claude/skills/deploy")
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try "---\ndescription: \"Commits it\"\n---\n".write(to: commands.appendingPathComponent("commit.md"), atomically: true, encoding: .utf8)
    try "---\nname: deploy\ndescription: Ships it\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let all = SlashCatalog.all(project: "/nowhere", home: home)
    #expect(all.contains(ComposerCompletion(insert: "/git:commit", detail: "Commits it")))
    #expect(all.contains(ComposerCompletion(insert: "/deploy", detail: "Ships it")))
    #expect(all.contains { $0.insert == "/clear" })
}

@Test func fileMatchesRankTheNameAboveThePath() {
    let files = ["Sources/App/main.swift", "Sources/Main/Other.swift", "docs/domain.md", "README.md"]
    #expect(FileCatalog.matching("main", in: files).map(\.insert) == ["@Sources/App/main.swift", "@docs/domain.md", "@Sources/Main/Other.swift"])
}

@Test func historyIsTheFoldersPromptsWithPastesFilledIn() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let lines = [
        #"{"display":"first","project":"/work/a"}"#,
        #"{"display":"elsewhere","project":"/work/b"}"#,
        #"{"display":"look [Pasted text #1 +2 lines]","pastedContents":{"1":{"id":1,"type":"text","content":"x\ny"}},"project":"/work/a"}"#,
        #"{"display":"look [Pasted text #1 +2 lines]","pastedContents":{"1":{"id":1,"type":"text","content":"x\ny"}},"project":"/work/a"}"#,
    ]
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    #expect(PromptHistory.prompts(for: "/work/a", in: url) == ["first", "look x\ny"])
}

@Test func theStatusLineSaysModelContextAndCost() {
    let live = MaestroLive(statusInput: [
        "cost": ["total_cost_usd": 3.214],
        "context_window": ["context_window_size": 200_000, "current_usage": ["input_tokens": 1000, "cache_read_input_tokens": 83000]],
    ])
    #expect(live == MaestroLive(context: 42, cost: 3.21))
    #expect(MaestroLive(statusInput: ["context_window": ["used_percentage": 17.6]]).context == 18)
    #expect(MaestroLive.line(model: MaestroModel(name: "Opus 5.5", effort: "medium"), live: live) == "Opus 5.5 · medium · contexto 42% · US$ 3,21")
    #expect(MaestroLive.line(model: nil, live: nil) == "")
}

import Foundation
import Testing
@testable import VitraOrchestrator

private let start = Date(timeIntervalSince1970: 1_000_000)

/// One finished review, as the scoreboard and the trial rules see it.
private func review(
    _ cli: WorkerCLI,
    _ model: String,
    effort: String? = nil,
    score: Int? = nil
) -> Run {
    Run(
        id: "0123abcd",
        spec: WorkerSpec(
            cli: cli, model: model, prompt: "review", directory: "/tmp",
            kind: .review, effort: effort
        ),
        state: .finished(exitCode: 0),
        pid: 4242,
        started: start,
        ended: start.addingTimeInterval(10),
        output: WorkerOutput(text: "ok", isError: false),
        errorTail: nil,
        rating: score.map { Rating(score: $0, note: nil, rated: start) }
    )
}

private func implementer(_ cli: WorkerCLI) -> WorkerSpec {
    WorkerSpec(
        cli: cli,
        model: cli == .claude ? "haiku" : "opencode/a-free",
        prompt: "change the code",
        directory: "/tmp",
        access: .edit,
        effort: cli == .claude ? "low" : nil
    )
}

@Test func theBestRatedReviewerFromAnotherProviderAudits() {
    // Three providers have a review record, so the trial is over and the
    // scoreboard's order decides: the highest rated first.
    let history = [
        review(.gemini, "gemini-3.8-flash-low", score: 5),
        review(.opencode, "opencode/a-free", score: 4),
        review(.cursor, "grok-4.7-low-fast", score: 3),
    ]
    let chosen = Audit.chooseAuditor(
        implementer: implementer(.claude),
        history: history,
        installed: [.claude, .opencode, .gemini, .cursor]
    )
    #expect(chosen?.cli == .gemini)
    #expect(chosen?.model == "gemini-3.8-flash-low")
    #expect(chosen?.effort == nil)
}

@Test func theImplementersOwnProviderIsNeverTheAuditor() {
    // claude is ranked first, and cannot audit a claude delivery: a sibling
    // misses what its sibling missed.
    let history = [
        review(.claude, "haiku", effort: "low", score: 5),
        review(.gemini, "gemini-3.8-flash-low", score: 4),
        review(.opencode, "opencode/a-free", score: 3),
    ]
    let chosen = Audit.chooseAuditor(
        implementer: implementer(.claude),
        history: history,
        installed: [.claude, .gemini, .opencode]
    )
    #expect(chosen?.cli == .gemini)
}

@Test func withNoReviewRecordTheCheapListIsUsedInOrder() {
    let installed: Set<WorkerCLI> = [.claude, .opencode, .cursor, .gemini]
    #expect(Audit.chooseAuditor(implementer: implementer(.claude), history: [], installed: installed)?.cli == .opencode)
    #expect(Audit.chooseAuditor(implementer: implementer(.opencode), history: [], installed: installed)?.cli == .cursor)
    #expect(Audit.chooseAuditor(implementer: implementer(.cursor), history: [], installed: installed)?.cli == .claude)
    #expect(Audit.chooseAuditor(implementer: implementer(.gemini), history: [], installed: installed)?.cli == .opencode)

    let cheapest = Audit.chooseAuditor(implementer: implementer(.claude), history: [], installed: installed)
    #expect(cheapest?.model == "opencode/glm-5.3-flash-free")
    #expect(cheapest?.effort == nil)
}

@Test func anUninstalledCLIIsNotAnAuditor() {
    let chosen = Audit.chooseAuditor(
        implementer: implementer(.claude),
        history: [],
        installed: [.claude, .gemini]
    )
    #expect(chosen?.cli == .gemini)
    #expect(chosen?.model == "gemini-3.8-flash-low")
}

@Test func aReviewerTheTrialRulesRefuseIsPassedOver() {
    // One provider has a review rating, so the trial still refuses a worker
    // already rated on review — the cheap fallback is that same worker here.
    let history = [review(.opencode, "opencode/glm-5.3-flash-free", score: 4)]
    let chosen = Audit.chooseAuditor(
        implementer: implementer(.claude),
        history: history,
        installed: [.claude, .opencode]
    )
    #expect(chosen == nil)
}

@Test func noAuditorWhenEveryCandidateIsGone() {
    // Only the implementer's own CLI is installed, and it may not audit itself.
    #expect(Audit.chooseAuditor(implementer: implementer(.claude), history: [], installed: [.claude]) == nil)
}

@Test func theAuditorIsToldTheTaskTheDiffAndHowToAnswer() {
    let prompt = Audit.prompt(
        task: "Add a logout button",
        diff: "diff --git a/Login.swift b/Login.swift",
        label: "logout"
    )
    #expect(prompt.contains("Add a logout button"))
    #expect(prompt.contains("diff --git a/Login.swift b/Login.swift"))
    #expect(prompt.contains("logout"))
    // It reviews and edits nothing.
    #expect(prompt.contains("do not edit"))
    // The first line is a verdict from a fixed list.
    #expect(prompt.contains("`ship`"))
    #expect(prompt.contains("`ship after fixes`"))
    #expect(prompt.contains("`do not ship`"))
    // Findings are real failures, placed and shown.
    #expect(prompt.contains("file:line"))
    #expect(prompt.contains("failure scenario"))
    #expect(prompt.contains("security"))
}

@Test func aHugeDiffIsCutAndTheAuditorIsSentToTheFiles() {
    let diff = String(repeating: "x", count: Audit.longestDiff + 500)
    let prompt = Audit.prompt(task: "task", diff: diff, label: nil)

    #expect(prompt.contains(String(repeating: "x", count: Audit.longestDiff)))
    #expect(!prompt.contains(String(repeating: "x", count: Audit.longestDiff + 1)))
    #expect(prompt.contains("the diff was cut: 500 more characters"))
    #expect(prompt.contains("in this directory"))
}

import Foundation
import Testing
@testable import VitraOrchestrator

private let start = Date(timeIntervalSince1970: 1_000_000)

private func worker(_ cli: WorkerCLI, _ model: String, effort: String? = nil, kind: TaskKind = .implement) -> WorkerSpec {
    WorkerSpec(cli: cli, model: model, prompt: "go", directory: "/tmp", kind: kind, effort: effort)
}

private func done(_ spec: WorkerSpec, score: Int? = 4, at began: Date = start) -> Run {
    Run(
        id: "0123abcd", spec: spec, state: .finished(exitCode: 0), pid: 4242, started: began,
        ended: began.addingTimeInterval(10), output: WorkerOutput(text: "ok", isError: false),
        errorTail: nil, rating: score.map { Rating(score: $0, note: nil, rated: began) }
    )
}

@Test func afterFourPiecesToRatedWorkersTheFifthIsAnExplorationTurn() {
    let sonnet = worker(.claude, "sonnet", effort: "high")
    let flash = worker(.gemini, "gemini-3.8-flash-low")
    // Three providers rated: the trial is over. Older history first.
    let older = [done(sonnet), done(flash), done(worker(.opencode, "opencode/x-free"))]
    let recent = (1...4).map { step in
        done(step.isMultiple(of: 2) ? sonnet : flash, at: start.addingTimeInterval(Double(step)))
    }
    let history = older + recent

    let refusal = TrialRules.problem(with: sonnet, history: history, providers: 4)
    #expect(refusal?.hasPrefix("implement is due an exploration turn") == true)
    #expect(refusal?.contains("already has one") == true)
    // A worker with no record on the kind is always allowed.
    #expect(TrialRules.problem(with: worker(.cursor, "cursor-grok-4.6-low-fast"), history: history, providers: 4) == nil)
    // Only three recent pieces: no exploration turn yet.
    // The fourth most recent is an untried worker's piece, so no refusal.
    let untriedBefore = done(worker(.cursor, "cursor-grok-4.6-low-fast"), score: nil, at: start.addingTimeInterval(0.5))
    #expect(TrialRules.problem(with: sonnet, history: older + [untriedBefore] + recent.dropFirst(), providers: 4) == nil)
    // An untried worker in the last four lifts the refusal.
    let fresh = done(worker(.cursor, "cursor-grok-4.6-low-fast"), score: nil, at: start.addingTimeInterval(5))
    #expect(TrialRules.problem(with: sonnet, history: history + [fresh], providers: 4) == nil)
    // Exploration is not checked while the trial is still on.
    #expect(TrialRules.problem(with: sonnet, history: [done(sonnet), done(sonnet, at: start.addingTimeInterval(1))], providers: 4)?.contains("still in its trial") == true)
}

@Test func aWorkerAlreadyRatedOnAKindWaitsUntilThreeProvidersHaveBeen() {
    let sonnet = worker(.claude, "sonnet", effort: "high")
    let history = [done(sonnet)]
    let refusal = TrialRules.problem(with: sonnet, history: history, providers: 4)
    #expect(refusal?.contains("still in its trial: 1 of 3 providers") == true)
    // Another worker, even from the same provider, is welcome.
    #expect(TrialRules.problem(with: worker(.claude, "opus", effort: "low"), history: history, providers: 4) == nil)
    // A rating on another kind does not count against this one.
    #expect(TrialRules.problem(with: worker(.claude, "sonnet", effort: "high", kind: .review), history: history, providers: 4) == nil)

    let three = history + [done(worker(.gemini, "gemini-3.8-flash-low")), done(worker(.opencode, "opencode/x-free"))]
    #expect(TrialRules.problem(with: sonnet, history: three, providers: 4) == nil)
    // With only two CLIs installed, two providers is the most there can be.
    let two = history + [done(worker(.gemini, "gemini-3.8-flash-low"))]
    #expect(TrialRules.problem(with: sonnet, history: two, providers: 2) == nil)
}

@Test func aModelIsTriedAtItsLowestEffortBeforeAHigherOne() {
    let refusal = TrialRules.problem(with: worker(.cursor, "grok-4.7-high"), history: [], providers: 4)
    #expect(refusal?.contains("use grok-4.7-low first") == true)
    #expect(TrialRules.problem(with: worker(.cursor, "grok-4.7-low-fast"), history: [], providers: 4) == nil)
    #expect(TrialRules.problem(with: worker(.cursor, "grok-4.7-xhigh-fast"), history: [], providers: 4)?.contains("grok-4.7-low-fast") == true)
    #expect(TrialRules.problem(with: worker(.gemini, "gemini-3.8-flash-medium"), history: [], providers: 4)?.contains("gemini-3.8-flash-low") == true)
    #expect(TrialRules.problem(with: worker(.claude, "haiku", effort: "high"), history: [], providers: 4)?.contains("haiku at effort low") == true)
    // Sonnet and opus are offered at one effort each: nothing lower to try.
    #expect(TrialRules.problem(with: worker(.claude, "sonnet", effort: "high"), history: [], providers: 4) == nil)

    // Once the lower one has run on this kind, however it did, up is open.
    let tried = [done(worker(.cursor, "grok-4.7-low"), score: 2)]
    #expect(TrialRules.problem(with: worker(.cursor, "grok-4.7-high"), history: tried, providers: 4) == nil)
    // A lower run on another kind does not count.
    let elsewhere = [done(worker(.cursor, "grok-4.7-low", kind: .explore))]
    #expect(TrialRules.problem(with: worker(.cursor, "grok-4.7-high"), history: elsewhere, providers: 4) != nil)
}

import Foundation
import Testing
@testable import VitraOrchestrator

private let start = Date(timeIntervalSince1970: 1_000_000)

private func worker(_ cli: WorkerCLI, _ model: String, effort: String? = nil, kind: TaskKind = .implement) -> WorkerSpec {
    WorkerSpec(cli: cli, model: model, prompt: "go", directory: "/tmp", kind: kind, effort: effort)
}

private func done(_ spec: WorkerSpec, score: Int? = 4) -> Run {
    Run(
        id: "0123abcd", spec: spec, state: .finished(exitCode: 0), pid: 4242, started: start,
        ended: start.addingTimeInterval(10), output: WorkerOutput(text: "ok", isError: false),
        errorTail: nil, rating: score.map { Rating(score: $0, note: nil, rated: start) }
    )
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

import Foundation
import Testing
@testable import VitraOrchestrator

private let start = Date(timeIntervalSince1970: 1_000_000)
private let now = start.addingTimeInterval(3 * 3600)

private func offer(_ cli: WorkerCLI, _ model: String, _ effort: String? = nil) -> ModelCatalog.Offer {
    ModelCatalog.Offer(cli: cli, model: model, effort: effort)
}

private let haikuLow = offer(.claude, "haiku", "low")
private let haikuMedium = offer(.claude, "haiku", "medium")
private let haikuHigh = offer(.claude, "haiku", "high")
private let sonnet = offer(.claude, "sonnet", "high")
private let glm = offer(.opencode, "opencode/glm-5.3-flash-free")
private let grokLow = offer(.cursor, "grok-4.7-low-fast")
private let grokHigh = offer(.cursor, "grok-4.7-high-fast")
private let geminiLow = offer(.gemini, "gemini-3.8-flash-low")

/// `count` runs of `worker` on `kind`, a second apart from `at`.
private func runs(
    _ worker: ModelCatalog.Offer,
    _ count: Int = 1,
    kind: TaskKind = .review,
    seconds: TimeInterval = 10,
    cost: Double = 0,
    score: Int? = nil,
    failed: Bool = false,
    at began: Date = start
) -> [Run] {
    (0..<count).map { index in
        let started = began.addingTimeInterval(Double(index))
        return Run(
            id: "0123abcd",
            spec: WorkerSpec(
                cli: worker.cli, model: worker.model, prompt: "go", directory: "/tmp",
                kind: kind, effort: worker.effort
            ),
            state: .finished(exitCode: failed ? 1 : 0),
            pid: 4242,
            started: started,
            ended: started.addingTimeInterval(seconds),
            output: WorkerOutput(text: failed ? "no" : "ok", isError: failed, costUSD: cost),
            errorTail: nil,
            rating: score.map { Rating(score: $0, note: nil, rated: started) }
        )
    }
}

private let installed: Set<WorkerCLI> = [.claude, .opencode, .gemini, .cursor]

private func pick(
    _ offers: [ModelCatalog.Offer],
    _ history: [Run] = [],
    kind: TaskKind = .review,
    access: WorkerAccess = .read,
    needsCommands: Bool = false,
    installed: Set<WorkerCLI> = installed,
    excluded: Set<WorkerCLI> = []
) -> WorkerPicker.Choice? {
    WorkerPicker.pick(
        kind: kind, access: access, needsCommands: needsCommands, history: history,
        offers: offers, installed: installed, excluded: excluded, now: now
    )
}

// MARK: Learning

@Test func learningTriesTheCheapestWorkerFirstAndFreeOnesCostNothing() {
    // Catalogue order lists the dear ones first; cost decides.
    let choice = pick([sonnet, haikuLow, glm])
    #expect(choice?.offer == glm)
    #expect(choice?.reason == "learning, 0 of 2 runs on review")
    // Among claude, by tier: haiku low < medium < high < sonnet high.
    #expect(pick([sonnet, haikuHigh, haikuMedium, haikuLow], installed: [.claude])?.offer == haikuLow)
}

@Test func theCLIWithTheFewestRunsOnTheKindBreaksACostTie() {
    // Both free; opencode already has a run on review, cursor none.
    let history = runs(glm, 1)
    #expect(pick([glm, grokLow], history)?.offer == grokLow)
    // A run on another kind is not a run on this one.
    #expect(pick([glm, grokLow], runs(glm, 1, kind: .explore))?.offer == glm)
}

@Test func aHigherEffortIsTriedOnlyAfterALowerOneHasRun() {
    // The high one is listed first and costs the same, yet low goes first.
    #expect(pick([grokHigh, grokLow])?.offer == grokLow)
    // One run of low is enough to open high, once low has had its deliveries.
    #expect(pick([grokHigh, grokLow], runs(grokLow, 2))?.offer == grokHigh)
    // For claude: medium waits for low, and high for low or medium.
    #expect(pick([haikuMedium, haikuHigh, haikuLow], runs(haikuLow, 2), installed: [.claude])?.offer == haikuMedium)
    // A model with no lower effort on offer is not held back.
    #expect(pick([sonnet], installed: [.claude])?.offer == sonnet)
}

@Test func theEffortBelongsToTheWorkerSoOneEffortsRunsDoNotCloseAnother() {
    // haiku at low has its two deliveries; haiku at medium has none.
    let choice = pick([haikuLow, haikuMedium], runs(haikuLow, 2), installed: [.claude])
    #expect(choice?.offer == haikuMedium)
    #expect(choice?.reason == "learning, 0 of 2 runs on review")
}

@Test func twoDeliveriesEndLearning() {
    #expect(pick([glm], runs(glm, 1, score: 5))?.reason == "learning, 1 of 2 runs on review")
    // A failed run is not a delivery.
    #expect(pick([glm], runs(glm, 1) + runs(glm, 1, failed: true, at: start.addingTimeInterval(5)))?.reason
        == "learning, 1 of 2 runs on review")
    let done = pick([glm], runs(glm, 2, score: 5))
    #expect(done?.offer == glm)
    #expect(done?.reason.hasPrefix("fastest rated 4 or more on review") == true)
}

// MARK: Exploitation

@Test func exploitationTakesTheFastestWorkerRatedFourOrMore() {
    // Five runs of the kind, so the turn is not an exploration one.
    let history = runs(glm, 2, seconds: 30, score: 5) + runs(grokLow, 3, seconds: 12, score: 4)
    #expect(pick([glm, grokLow], history)?.offer == grokLow)
    // Rated below four, a worker is not exploited however fast it is.
    let fastButPoor = runs(glm, 2, seconds: 1, score: 3) + runs(grokLow, 3, seconds: 12, score: 4)
    #expect(pick([glm, grokLow], fastButPoor)?.offer == grokLow)
}

@Test func equalTimesAreSeparatedByTheMedianCost() {
    let history = runs(sonnet, 2, seconds: 10, cost: 0.30, score: 5) + runs(haikuLow, 3, seconds: 10, cost: 0.02, score: 5)
    #expect(pick([sonnet, haikuLow], history, installed: [.claude])?.offer == haikuLow)
}

@Test func everyFifthPieceOfAKindGoesToTheLeastUsedWorker() {
    // The fast worker is the free one; the slow one the dear one. Four runs
    // of the kind so far: the fifth is an exploration turn, tied on runs and
    // broken by cost.
    let fast = runs(sonnet, 2, seconds: 10, score: 5)
    let slow = runs(glm, 2, seconds: 40, score: 5, at: start.addingTimeInterval(10))
    let turn = pick([sonnet, glm], fast + slow)
    #expect(turn?.offer == glm)
    #expect(turn?.reason == "every fifth piece goes to the least used worker: 2 runs on review")
    // A fifth run of the kind and the next one is exploitation again.
    let more = runs(sonnet, 1, seconds: 10, score: 5, at: start.addingTimeInterval(20))
    #expect(pick([sonnet, glm], fast + slow + more)?.offer == sonnet)
    // Nine runs: sonnet 5, glm 4 — the fewest runs is the one that goes.
    let nine = runs(sonnet, 5, seconds: 10, score: 5) + runs(glm, 4, seconds: 40, score: 5, at: start.addingTimeInterval(10))
    #expect(pick([sonnet, glm], nine)?.offer == glm)
}

@Test func theExplorationTurnPassesOverAWorkerKnownBad() {
    let rated = runs(glm, 2, score: 5) + runs(grokLow, 2, score: 5, at: start.addingTimeInterval(10))
    let bad = runs(haikuLow, 3, score: 2, at: start.addingTimeInterval(20))
    // Nine runs of the kind, so it is a turn; glm has four, grok two, and
    // haiku three but is known bad, so grok goes.
    let nine = rated + bad + runs(glm, 2, score: 5, at: start.addingTimeInterval(30))
    #expect(nine.count == 9)
    let choice = pick([haikuLow, glm, grokLow], nine, installed: [.claude, .opencode, .cursor])
    #expect(choice?.offer == grokLow)
    #expect(choice?.reason == "every fifth piece goes to the least used worker: 2 runs on review")
}

@Test func withNoWorkerRatedFourTheCheapestEligibleGoes() {
    // Two deliveries each and no rating: not learning, not exploited.
    let history = runs(sonnet, 2) + runs(haikuLow, 2, at: start.addingTimeInterval(5))
    let choice = pick([sonnet, haikuLow], history, installed: [.claude])
    #expect(choice?.offer == haikuLow)
    #expect(choice?.reason == "cheapest that may run; none is rated 4 or more on review")
}

// MARK: Known bad

@Test func knownBadIsPerWorkerAndNeverPerProviderOrPerEffort() {
    // haiku at low is rated 2: never picked on its own again ...
    let history = runs(haikuLow, 2, score: 2)
    #expect(pick([haikuLow], history, installed: [.claude]) == nil)
    // ... but haiku at medium, the same model, is its own worker and is next ...
    #expect(pick([haikuLow, haikuMedium], history, installed: [.claude])?.offer == haikuMedium)
    // ... and so is another model of the same provider.
    #expect(pick([haikuLow, sonnet], history, installed: [.claude])?.offer == sonnet)
    // A single rating below four is enough; an average of four is not bad.
    #expect(pick([glm], runs(glm, 1, score: 3) + runs(glm, 1, score: 5, at: start.addingTimeInterval(1)))?.offer == glm)
    #expect(pick([glm], runs(glm, 1, score: 3)) == nil)
}

// MARK: Eligibility

@Test func commandsKeepCursorAndGeminiOutOfTheChoice() {
    let all = [grokLow, geminiLow, haikuLow]
    // Without commands the free ones come first.
    #expect(pick(all, kind: .explore)?.offer == grokLow)
    #expect(pick(all, kind: .explore, needsCommands: true)?.offer == haikuLow)
    #expect(pick([grokLow, geminiLow], needsCommands: true) == nil)
}

@Test func geminiOnlyReadsAndOnlyExploresReviewsAndDocs() {
    #expect(pick([geminiLow], kind: .explore)?.offer == geminiLow)
    #expect(pick([geminiLow], kind: .docs)?.offer == geminiLow)
    #expect(pick([geminiLow], kind: .explore, access: .edit) == nil)
    #expect(pick([geminiLow], kind: .implement) == nil)
    #expect(pick([geminiLow], kind: .test) == nil)
}

@Test func aCLIThatFailedWithoutRunningRecentlyIsSkipped() {
    // "Free usage limit reached", out in 5 seconds, ten minutes ago.
    let limit = runs(glm, 1, seconds: 5, failed: true, at: now.addingTimeInterval(-600))
    #expect(pick([glm, grokLow], limit)?.offer == grokLow)
    // Any kind of run counts: it is the CLI that is out, not the kind.
    let other = runs(glm, 1, kind: .explore, seconds: 5, failed: true, at: now.addingTimeInterval(-600))
    #expect(pick([glm, grokLow], other)?.offer == grokLow)
    // Half an hour on, it is tried again. (These are runs of another kind, so
    // they do not tip the CLI-with-fewest-runs tie-break on review.)
    let old = runs(glm, 1, kind: .explore, seconds: 5, failed: true, at: now.addingTimeInterval(-31 * 60))
    #expect(pick([glm, grokLow], old)?.offer == glm)
    // A failure that ran for a while was a real attempt, not a quota.
    let slow = runs(glm, 1, kind: .explore, seconds: 90, failed: true, at: now.addingTimeInterval(-600))
    #expect(pick([glm, grokLow], slow)?.offer == glm)
    // A later run that worked lifts it: the latest run decides.
    let recovered = other + runs(glm, 1, kind: .explore, seconds: 8, at: now.addingTimeInterval(-300))
    #expect(pick([glm, grokLow], recovered)?.offer == glm)
}

@Test func excludedAndUninstalledCLIsAreNotPicked() {
    #expect(pick([glm, grokLow], excluded: [.opencode])?.offer == grokLow)
    #expect(pick([glm, grokLow], installed: [.opencode])?.offer == glm)
    #expect(pick([glm, grokLow], installed: [.claude]) == nil)
    #expect(pick([], installed: installed) == nil)
}

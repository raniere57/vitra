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
    providerFailure: ProviderFailure? = nil,
    difficulty: Difficulty? = nil,
    at began: Date = start
) -> [Run] {
    (0..<count).map { index in
        let started = began.addingTimeInterval(Double(index))
        return Run(
            id: "0123abcd",
            spec: WorkerSpec(
                cli: worker.cli, model: worker.model, prompt: "go", directory: "/tmp",
                kind: kind, effort: worker.effort, difficulty: difficulty
            ),
            state: .finished(exitCode: failed ? 1 : 0),
            pid: 4242,
            started: started,
            ended: started.addingTimeInterval(seconds),
            output: WorkerOutput(text: failed ? "no" : "ok", isError: failed, costUSD: cost),
            errorTail: nil,
            rating: score.map { Rating(score: $0, note: nil, rated: started) },
            providerFailure: providerFailure
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
    excluded: Set<WorkerCLI> = [],
    difficulty: Difficulty = .normal,
    now at: Date = now
) -> WorkerPicker.Choice? {
    WorkerPicker.pick(
        kind: kind, access: access, needsCommands: needsCommands, history: history,
        offers: offers, installed: installed, excluded: excluded, difficulty: difficulty, now: at
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
    #expect(pick([glm], runs(glm, 1))?.reason == "learning, 1 of 2 runs on review")
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

@Test func aProvenWorkerDoesTheWorkAndLearningIsOnlyEveryFifthPiece() {
    // glm is rated on review; the Groks are untried. Learning them is a turn.
    let offers = [glm, grokLow, grokHigh]
    #expect(pick(offers, runs(glm, 2, score: 5))?.offer == glm)
    #expect(pick(offers, runs(glm, 3, score: 5))?.offer == glm)
    let fifth = pick(offers, runs(glm, 4, score: 5))
    #expect(fifth?.offer == grokLow)
    #expect(fifth?.reason == "learning, 0 of 2 runs on review")
}

@Test func twoRunsWithNothingDeliveredRuleAWorkerOut() {
    let broken = runs(geminiLow, 2, failed: true)
    #expect(pick([geminiLow, glm], broken)?.offer == glm)
    // One failure is not a verdict yet.
    #expect(pick([geminiLow], runs(geminiLow, 1, failed: true))?.offer == geminiLow)
    #expect(pick([geminiLow], broken) == nil)
}

// MARK: Provider failures

private let quota = ProviderFailure.quota("Free usage limit reached")

@Test func runsThatNeverRanBecauseOfTheirProviderAreNotHeldAgainstAWorker() {
    // Long enough ago that nothing is stalled any more.
    let long = now.addingTimeInterval(-2 * 3600)
    // Two failures that delivered nothing would rule a worker out; these are not runs.
    let history = runs(glm, 2, failed: true, providerFailure: quota, at: long)
    #expect(pick([glm], history)?.offer == glm)
    #expect(pick([glm], history)?.reason == "learning, 0 of 2 runs on review")

    // Nor do they move the every-fifth-piece count: four real runs would make
    // the next one a learning turn, two real runs and two quota failures do not.
    let offers = [glm, grokLow]
    #expect(pick(offers, runs(glm, 2, score: 5) + runs(glm, 2, failed: true, providerFailure: quota, at: long))?.offer == glm)
    #expect(pick(offers, runs(glm, 4, score: 5))?.offer == grokLow)
}

@Test func aProvidersOwnWordsKeepItsCLIOutForAsLongAsTheKindSays() {
    // Each ran for five minutes, so no guess from speed could explain it.
    func isOut(_ failure: ProviderFailure, endedMinutesAgo minutes: Double, kind: TaskKind = .explore) -> Bool {
        let started = now.addingTimeInterval(-minutes * 60 - 300)
        let history = runs(glm, 1, kind: kind, seconds: 300, failed: true, providerFailure: failure, at: started)
        return pick([glm, grokLow], history)?.offer == grokLow
    }
    // Quota: an hour, from any kind of run.
    #expect(isOut(quota, endedMinutesAgo: 59))
    #expect(isOut(quota, endedMinutesAgo: 59, kind: .review))
    #expect(!isOut(quota, endedMinutesAgo: 61))
    // Down: ten minutes.
    #expect(isOut(.unavailable("503 Service Unavailable"), endedMinutesAgo: 9))
    #expect(!isOut(.unavailable("503 Service Unavailable"), endedMinutesAgo: 11))
    // Signed out: until the user signs in again, however long that takes.
    let signedOut = ProviderFailure.signedOut("Authentication required")
    #expect(isOut(signedOut, endedMinutesAgo: 600))
    #expect(isOut(signedOut, endedMinutesAgo: 60 * 24 * 3))
}

@Test func aLaterRunThatWorkedLiftsAStallAndAQuickFailureWithWordsIsNotGuessedAt() {
    let failedLong = now.addingTimeInterval(-3 * 3600)
    let signedOut = runs(glm, 1, kind: .explore, seconds: 300, failed: true, providerFailure: .signedOut("Not logged in"), at: failedLong)
    #expect(pick([glm, grokLow], signedOut)?.offer == grokLow)
    // The user signed in and a run delivered: the CLI is back.
    let back = signedOut + runs(glm, 1, kind: .explore, seconds: 8, at: failedLong.addingTimeInterval(3600))
    #expect(pick([glm, grokLow], back)?.offer == glm)
    // A later failure that is not the provider's does not lift it.
    let stillOut = signedOut + runs(glm, 1, kind: .explore, seconds: 300, failed: true, at: failedLong.addingTimeInterval(3600))
    #expect(pick([glm, grokLow], stillOut)?.offer == grokLow)

    // A provider that was down for 5 seconds eleven minutes ago is back: the
    // 60-second heuristic is only for failures nobody put words to.
    let blip = runs(glm, 1, kind: .explore, seconds: 5, failed: true, providerFailure: .unavailable("overloaded"), at: now.addingTimeInterval(-11 * 60))
    #expect(pick([glm, grokLow], blip)?.offer == glm)
    let unexplained = runs(glm, 1, kind: .explore, seconds: 5, failed: true, at: now.addingTimeInterval(-11 * 60))
    #expect(pick([glm, grokLow], unexplained)?.offer == grokLow)
}

// MARK: Circuit breaker

private func failures(_ worker: ModelCatalog.Offer, _ count: Int, kind: TaskKind = .explore, minutesAgo: Double) -> [Run] {
    runs(worker, count, kind: kind, seconds: 100, failed: true, at: now.addingTimeInterval(-minutesAgo * 60))
}

@Test func aWorkerThatFailedThreeTimesInARowRestsAndTheReasonSaysSo() throws {
    let three = failures(glm, 3, minutesAgo: 20)
    let until = try #require(three.last?.ended).addingTimeInterval(30 * 60)

    let choice = pick([glm, grokLow], three)
    #expect(choice?.offer == grokLow)
    #expect(choice?.reason == "learning, 0 of 2 runs on review; "
        + "opencode opencode/glm-5.3-flash-free is resting until \(WorkerPicker.clock(until)) after 3 failures in a row")
    // Nobody else to take it: nothing may run.
    #expect(pick([glm], three) == nil)
    // Two are not enough, and the reason says nothing when the choice is the same.
    #expect(pick([glm, grokLow], failures(glm, 2, minutesAgo: 20))?.offer == glm)
    #expect(pick([grokLow, glm], three)?.reason == "learning, 0 of 2 runs on review")
}

@Test func theBreakerCountsRunsOfAnyKindAndOnlyTheWorkerThatFailed() {
    let mixed = failures(glm, 1, kind: .explore, minutesAgo: 20)
        + failures(glm, 1, kind: .test, minutesAgo: 18)
        + failures(glm, 1, kind: .docs, minutesAgo: 16)
    #expect(pick([glm, grokLow], mixed)?.offer == grokLow)
    // A worker is a cli, a model and an effort: haiku at low resting leaves haiku at high alone.
    let low = failures(haikuLow, 3, minutesAgo: 20)
    #expect(pick([haikuLow, haikuHigh], low, installed: [.claude])?.offer == haikuHigh)
    #expect(pick([haikuLow, haikuHigh], failures(grokLow, 3, minutesAgo: 20), installed: [.claude, .cursor])?.offer == haikuLow)
}

@Test func aSuccessClosesTheBreakerAndTimeExpiresIt() {
    let three = failures(glm, 3, minutesAgo: 20)
    // A delivery since, rated poorly or not, is a worker that works.
    #expect(pick([glm, grokLow], three + runs(glm, 1, kind: .explore, seconds: 8, at: now.addingTimeInterval(-5 * 60)))?.offer == glm)
    // The rest lasts half an hour from the last failure.
    #expect(pick([glm, grokLow], failures(glm, 3, minutesAgo: 31 + 2))?.offer == glm)
    #expect(pick([glm, grokLow], failures(glm, 3, minutesAgo: 28 + 2))?.offer == grokLow)
    // Failures spread over more than half an hour are not "in a row" in time.
    let spread = failures(glm, 1, minutesAgo: 50) + failures(glm, 1, minutesAgo: 30) + failures(glm, 1, minutesAgo: 10)
    #expect(pick([glm, grokLow], spread)?.offer == glm)
}

@Test func aProviderFailureOrAStoppedRunIsNeitherAFailureNorABreakInTheRow() {
    // Two failures of its own and one of its provider's: two failures.
    let provider = runs(glm, 1, kind: .explore, seconds: 100, failed: true, providerFailure: quota, at: now.addingTimeInterval(-9 * 60))
    #expect(WorkerPicker.resting(failures(glm, 2, minutesAgo: 20) + provider, now: now).isEmpty)
    // ... and between the third failure and the other two it breaks nothing.
    #expect(WorkerPicker.resting(failures(glm, 3, minutesAgo: 20) + provider, now: now).count == 1)
    let stopped = Run(
        id: "0123abcd", spec: WorkerSpec(cli: .opencode, model: glm.model, prompt: "go", directory: "/tmp"),
        state: .cancelled, pid: 1, started: now.addingTimeInterval(-9 * 60), ended: now.addingTimeInterval(-8 * 60),
        output: nil, errorTail: nil
    )
    #expect(WorkerPicker.resting(failures(glm, 3, minutesAgo: 20) + [stopped], now: now).count == 1)
}

@Test func agentScoresSaysWhoIsResting() throws {
    let three = failures(glm, 3, minutesAgo: 20)
    let until = try #require(three.last?.ended).addingTimeInterval(30 * 60)
    let text = Scoreboard.summary(
        Scoreboard.scores(three), offers: [glm, grokLow], history: three, now: now
    )
    #expect(text.contains(
        "resting\n  opencode opencode/glm-5.3-flash-free — resting until \(WorkerPicker.clock(until)) after 3 failures in a row"
    ))
    #expect(!Scoreboard.summary(Scoreboard.scores(three), offers: [glm], history: three, now: now.addingTimeInterval(3600)).contains("resting"))
}

// MARK: Difficulty

private let opus = offer(.claude, "opus", "low")
private let grokXHigh = offer(.cursor, "grok-4.7-xhigh-fast")

@Test func strongWorkersAreSonnetOpusHaikuAtHighAndTheGroksAtHighOrXHigh() {
    for strong in [haikuHigh, sonnet, opus, grokHigh, grokXHigh, offer(.claude, "sonnet", "low")] {
        #expect(WorkerPicker.isStrong(strong), "\(strong.name)")
    }
    for light in [haikuLow, haikuMedium, grokLow, glm, geminiLow, offer(.opencode, "opencode/big-free", "high")] {
        #expect(!WorkerPicker.isStrong(light), "\(light.name)")
    }
}

@Test func aHardPieceGoesOnlyToStrongWorkersWhenAnyMayRunAndHasNoLearningTurns() {
    let all = [glm, haikuLow, haikuMedium, haikuHigh, sonnet, opus, grokLow, grokHigh]
    // The cheapest strong one: the Grok is free.
    let choice = pick(all, difficulty: .hard)
    #expect(choice?.offer == grokHigh)
    #expect(choice?.reason == "cheapest that may run; none is rated 4 or more on review, hard piece")
    #expect(pick(all, installed: [.claude], difficulty: .hard)?.offer == haikuHigh)
    #expect(pick(all, installed: [.opencode], difficulty: .hard)?.offer == glm, "with no strong one installed it goes on as normal")
    #expect(pick(all, installed: [.claude, .opencode], excluded: [.claude], difficulty: .hard)?.offer == glm)

    // The every-fifth learning turn is skipped for a hard piece.
    let proven = runs(sonnet, 4, score: 5)
    #expect(pick([sonnet, haikuHigh], proven)?.offer == haikuHigh)
    let hard = pick([sonnet, haikuHigh], proven, difficulty: .hard)
    #expect(hard?.offer == sonnet)
    #expect(hard?.reason.hasSuffix(", hard piece") == true)
    // ... and so is learning an untried worker while nobody is rated: the cheapest goes.
    #expect(pick([sonnet, haikuHigh], difficulty: .hard)?.offer == haikuHigh)
    #expect(pick([sonnet, haikuHigh])?.reason == "learning, 0 of 2 runs on review")
}

@Test func anEasyPieceStaysOffStrongWorkersWhenALighterOneMayRun() {
    #expect(pick([sonnet, haikuLow], difficulty: .easy)?.offer == haikuLow)
    #expect(pick([opus, grokHigh, glm], difficulty: .easy)?.offer == glm)
    // Nobody lighter: the strong one takes it.
    #expect(pick([sonnet, grokHigh], difficulty: .easy)?.offer == grokHigh)
    // A proven strong worker does not take it when a lighter one can learn.
    let choice = pick([sonnet, haikuLow], runs(sonnet, 2, score: 5), difficulty: .easy)
    #expect(choice?.offer == haikuLow)
    #expect(choice?.reason == "learning, 0 of 2 runs on review, easy piece")
    // Normal is as it was: the proven worker.
    #expect(pick([sonnet, haikuLow], runs(sonnet, 2, score: 5))?.offer == sonnet)
}

@Test func rankingUsesTheRunsOfTheSameDifficultyWhenAWorkerHasTwoOfThem() {
    let slowOnHard = runs(glm, 2, seconds: 5, score: 5, difficulty: .easy)
        + runs(glm, 2, seconds: 100, score: 5, difficulty: .hard, at: start.addingTimeInterval(10))
    // (Three, so that no total of runs lands on an every-fifth learning turn.)
    let steady = runs(grokLow, 3, seconds: 20, score: 5, at: start.addingTimeInterval(20))
    let history = slowOnHard + steady
    // Easy: glm's two easy runs, 5 s. Hard: its two hard runs, 100 s, so the
    // other is faster. Normal: glm has none, so all four count (52.5 s).
    #expect(pick([glm, grokLow], history, difficulty: .easy)?.offer == glm)
    #expect(pick([glm, grokLow], history, difficulty: .hard)?.offer == grokLow)
    #expect(pick([glm, grokLow], history, difficulty: .normal)?.offer == grokLow)
    // With one run of a difficulty a worker is judged on everything it did.
    let one = runs(glm, 1, seconds: 5, score: 5, difficulty: .easy) + runs(glm, 1, seconds: 100, score: 5, difficulty: .hard, at: start.addingTimeInterval(10))
    #expect(pick([glm, grokLow], one + steady, difficulty: .easy)?.offer == grokLow)
}

@Test func aSingleWorkerCanBeLeftOutOfThePick() {
    #expect(WorkerPicker.pick(
        kind: .review, access: .read, needsCommands: false, history: [], offers: [glm, grokLow],
        installed: installed, excludedWorkers: [glm], now: now
    )?.offer == grokLow)
    #expect(WorkerPicker.pick(
        kind: .review, access: .read, needsCommands: false, history: [], offers: [haikuLow, haikuMedium],
        installed: installed, excludedWorkers: [haikuLow], now: now
    )?.offer == haikuMedium)
}

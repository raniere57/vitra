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
private let opus = offer(.claude, "opus", "low")
private let glm = offer(.opencode, "opencode/glm-5.3-flash-free")
private let deepseek = offer(.opencode, "opencode/deepseek-v4.1-flash-free")
private let grokLow = offer(.cursor, "grok-4.7-low-fast")
private let grokHigh = offer(.cursor, "grok-4.7-high-fast")
private let grok46 = offer(.cursor, "cursor-grok-4.6-low-fast")
private let geminiLow = offer(.gemini, "gemini-3.8-flash-low")

/// Everything the default lineup names, and a little more.
private let catalogue = [haikuLow, haikuMedium, haikuHigh, sonnet, opus, glm, deepseek, grok46, grokLow, grokHigh, geminiLow]

/// No preference: the record alone decides.
private let noLineup = Lineup(hard: [], normal: [], easy: [])

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
    pick: PickReason? = nil,
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
            providerFailure: providerFailure,
            pick: pick
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
    lineup: Lineup = noLineup,
    now at: Date = now
) -> WorkerPicker.Choice? {
    WorkerPicker.pick(
        kind: kind, access: access, needsCommands: needsCommands, history: history,
        offers: offers, installed: installed, excluded: excluded, difficulty: difficulty, lineup: lineup, now: at
    )
}

// MARK: The lineup file

@Test func theLineupFileRoundTripsAndAMissingOrBrokenOneIsTheDefault() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-lineup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("lineup.json")

    #expect(Lineup.load(from: file) == .standard)
    #expect(Lineup.standard.hard == [opus, sonnet, haikuHigh, grokHigh])
    #expect(Lineup.standard.normal == [grok46, haikuLow, glm, deepseek, grokLow])
    #expect(Lineup.standard.easy == [grok46, glm, haikuLow])

    let mine = Lineup.standard.with(.hard, [sonnet, opus])
    try mine.save(to: file)
    #expect(Lineup.load(from: file) == mine)
    #expect(Lineup.load(from: file).version == Lineup.currentVersion)

    // A rewrite is seen at once, though the last read is cached.
    let later = mine.with(.easy, [glm])
    try later.save(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
    #expect(Lineup.load(from: file) == later)

    try Data("{ not json".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
    #expect(Lineup.load(from: file) == .standard)

    try Data(#"{"version": 99, "hard": [], "normal": [], "easy": []}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(15)], ofItemAtPath: file.path)
    #expect(Lineup.load(from: file) == .standard)
}

// MARK: The lineup decides

@Test func thePickerFollowsTheLineupAndSaysWhichPlace() {
    let hard = pick(catalogue, difficulty: .hard, lineup: .standard)
    #expect(hard?.offer == opus)
    #expect(hard?.reason == "1st in your lineup for hard pieces")
    #expect(hard?.pick == PickReason(code: .lineup, text: "1st in your lineup for hard pieces", position: 1))

    #expect(pick(catalogue, lineup: .standard)?.offer == grok46)
    #expect(pick(catalogue, difficulty: .easy, lineup: .standard)?.offer == grok46)
    // Cursor cannot be given commands: the next, and that is not news.
    let commands = pick(catalogue, needsCommands: true, lineup: .standard)
    #expect(commands?.offer == haikuLow)
    #expect(commands?.reason == "2nd in your lineup for normal pieces")
    // Not installed or not offered is the same.
    #expect(pick(catalogue, installed: [.opencode], difficulty: .easy, lineup: .standard)?.offer == glm)
    #expect(pick([sonnet, haikuHigh], difficulty: .hard, lineup: .standard)?.offer == sonnet)
}

@Test func aRecordDoesNotOverruleTheLineup() {
    // glm is proven and fast on review; the user still wants opus first on hard pieces.
    let history = runs(glm, 3, seconds: 5, score: 5, difficulty: .hard)
    #expect(pick(catalogue, history, difficulty: .hard, lineup: .standard)?.offer == opus)
}

@Test func aStalledOrRestingLineupWorkerIsPassedOverAndTheReasonSaysWhy() throws {
    // claude is out of quota: every claude worker on the hard tier is passed.
    let quota = runs(haikuLow, 1, kind: .explore, seconds: 300, failed: true,
                     providerFailure: .quota("usage limit"), at: now.addingTimeInterval(-10 * 60))
    let choice = pick(catalogue, quota, difficulty: .hard, lineup: .standard)
    #expect(choice?.offer == grokHigh)
    #expect(choice?.reason == "4th in your lineup: opus (low) is out of quota")
    #expect(choice?.pick.passed == "opus")
    #expect(choice?.pick.cause == .quota)
    #expect(choice?.pick.position == 4)

    // opus failed three times in a row: it rests, sonnet goes.
    let three = runs(opus, 3, kind: .explore, seconds: 100, failed: true, at: now.addingTimeInterval(-20 * 60))
    let until = try #require(three.last?.ended).addingTimeInterval(30 * 60)
    let resting = pick(catalogue, three, difficulty: .hard, lineup: .standard)
    #expect(resting?.offer == sonnet)
    #expect(resting?.reason == "2nd in your lineup: opus (low) is resting until \(WorkerPicker.clock(until)) after 3 failures in a row")
    #expect(resting?.pick.cause == .resting)
}

@Test func outsideTheLineupTheRecordDecides() {
    let lineup = Lineup(hard: [], normal: [glm], easy: [])
    // glm is excluded: the others, fastest rated 4 or more first.
    let history = runs(grokLow, 3, seconds: 12, score: 4) + runs(haikuLow, 2, seconds: 30, score: 5)
    let choice = pick([glm, grokLow, haikuLow], history, excluded: [.opencode], lineup: lineup)
    #expect(choice?.offer == grokLow)
    #expect(choice?.reason == "not in the lineup: fastest rated 4+ on review")
    #expect(choice?.pick.code == .record)
    // Nobody rated: the cheapest.
    let cheapest = pick([sonnet, haikuLow], installed: [.claude], lineup: lineup)
    #expect(cheapest?.offer == haikuLow)
    #expect(cheapest?.reason == "not in the lineup: cheapest that may run")
}

// MARK: Demotion

@Test func aLineupWorkerRatedBelowFourTwiceIsDemoted() {
    let poor = runs(opus, 2, score: 3, difficulty: .hard)
    // A third piece, so that this one is not a learning turn.
    let other = runs(sonnet, 1, score: 5, difficulty: .hard, at: start.addingTimeInterval(10))
    let choice = pick(catalogue, poor + other, difficulty: .hard, lineup: .standard)
    #expect(choice?.offer == sonnet)
    #expect(choice?.reason == "2nd in your lineup: opus (low) is demoted, rated 3.0 on review")
    #expect(choice?.pick.cause == .demoted)
    // One rating is not a record yet.
    #expect(pick(catalogue, runs(opus, 1, score: 2, difficulty: .hard), difficulty: .hard, lineup: .standard)?.offer == opus)
    // On another kind it is not demoted.
    #expect(pick(catalogue, poor, kind: .implement, difficulty: .hard, lineup: .standard)?.offer == opus)
    #expect(WorkerPicker.demotion(of: opus, kind: .review, difficulty: .hard, history: poor, next: sonnet) == .rating(3))
}

@Test func aLineupWorkerTwiceAsSlowAsTheNextIsDemoted() {
    let slow = runs(opus, 3, seconds: 300, score: 5, difficulty: .hard)
    let fast = runs(sonnet, 3, seconds: 100, score: 5, difficulty: .hard, at: start.addingTimeInterval(10))
    // A seventh piece, so that this one is not a learning turn.
    let other = runs(sonnet, 1, seconds: 100, score: 5, difficulty: .hard, at: start.addingTimeInterval(20))
    let choice = pick(catalogue, slow + fast + other, difficulty: .hard, lineup: .standard)
    #expect(choice?.offer == sonnet)
    #expect(choice?.reason == "2nd in your lineup: opus (low) is demoted, over twice as slow as sonnet (high) on review")
    #expect(choice?.pick.cause == .slow)
    // Exactly twice as slow is not more than twice.
    let twice = runs(opus, 3, seconds: 200, score: 5, difficulty: .hard)
    #expect(pick(catalogue, twice + fast, difficulty: .hard, lineup: .standard)?.offer == opus)
    // Two deliveries each are too few to compare.
    let few = Array(slow.prefix(2)) + Array(fast.prefix(2))
    #expect(pick(catalogue, few, difficulty: .hard, lineup: .standard)?.offer == opus)
}

@Test func aDemotedWorkerGetsItsChanceBackOnALearningTurn() {
    // Four hard reviews: the next is a learning turn. Opus, rated badly twice,
    // is in the cold for two days...
    let history = runs(opus, 2, score: 3, difficulty: .hard) + runs(sonnet, 2, score: 5, difficulty: .hard, at: start.addingTimeInterval(10))
    #expect(pick(catalogue, history, difficulty: .hard, lineup: .standard)?.offer != opus)
    // ... and takes the turn once they have passed.
    let turn = pick(catalogue, history, difficulty: .hard, lineup: .standard, now: start.addingTimeInterval(49 * 3600))
    #expect(turn?.offer == opus)
    #expect(turn?.reason == "learning turn")
    #expect(turn?.pick.code == .learning)
    // Rated well this time, its average is back to 4: first again.
    let redeemed = history + runs(opus, 2, score: 5, difficulty: .hard, at: start.addingTimeInterval(20))
    #expect(pick(catalogue, redeemed, difficulty: .hard, lineup: .standard)?.offer == opus)
}

// MARK: Learning turns

@Test func everyOtherPieceOfAKindAndDifficultyIsALearningTurn() {
    let proven = runs(grok46, 4, score: 5)
    let turn = pick(catalogue, proven, lineup: .standard)
    // The cheapest untried: free ones cost nothing, and a lower effort goes first.
    #expect(turn?.offer == glm)
    #expect(turn?.reason == "learning turn")
    // Three, or four of another difficulty, are not a turn.
    #expect(pick(catalogue, runs(grok46, 3, score: 5), lineup: .standard)?.offer == grok46)
    #expect(pick(catalogue, runs(grok46, 4, score: 5, difficulty: .easy), lineup: .standard)?.offer == grok46)
    // Never two in a row: the 1st of the lineup keeps the next piece.
    var after = proven
    after[3].pick = PickReason(code: .learning, text: "learning turn")
    #expect(pick(catalogue, after, lineup: .standard)?.offer == grok46)
}

@Test func aWorkerThatNeverRanAnythingLearnsBeforeOneKnownFromAnotherKind() {
    // glm has run, only not on reviews: deepseek, never used at all, goes first.
    let history = runs(grok46, 4, score: 5) + runs(glm, 2, kind: .implement, score: 5)
    #expect(pick(catalogue, history, lineup: .standard)?.offer == deepseek)
}

@Test func aHardPieceLearnsAmongStrongWorkersOnly() {
    let proven = runs(opus, 4, score: 5, difficulty: .hard)
    let turn = pick(catalogue, proven, difficulty: .hard, lineup: .standard)
    // The cheapest untried strong worker: the free Grok at high, once its low has run...
    #expect(turn?.offer != glm)
    #expect(turn.map { WorkerPicker.isStrong($0.offer) } == true)
    #expect(turn?.reason == "learning turn")
    // ... and with no Grok offered, never the light haiku low or glm: haiku at
    // high waits for its low to have run, so sonnet.
    let claude = pick([opus, sonnet, haikuHigh, haikuLow, glm], proven, difficulty: .hard, lineup: .standard)
    #expect(claude?.offer == sonnet)
    #expect(pick([opus, sonnet, haikuHigh], proven, difficulty: .hard, lineup: .standard)?.offer == haikuHigh)
}

@Test func runsThatNeverRanBecauseOfTheirProviderDoNotCountTowardsTheTurn() {
    let long = now.addingTimeInterval(-2 * 3600)
    let quota = runs(glm, 2, failed: true, providerFailure: .quota("limit"), at: long)
    #expect(pick(catalogue, runs(grok46, 3, score: 5) + quota, lineup: .standard)?.offer == grok46)
    #expect(pick(catalogue, runs(grok46, 4, score: 5), lineup: .standard)?.reason == "learning turn")
}

@Test func aHigherEffortIsLearnedOnlyAfterALowerOneHasRun() {
    // Four normal reviews by sonnet: a turn; haiku medium waits for haiku low.
    let proven = runs(sonnet, 4, score: 5)
    let lineup = Lineup(hard: [], normal: [sonnet], easy: [])
    #expect(pick([sonnet, haikuMedium, haikuLow], proven, installed: [.claude], lineup: lineup)?.offer == haikuLow)
    let lowRan = proven + runs(haikuLow, 2, score: 5, at: start.addingTimeInterval(10)) + runs(sonnet, 4, score: 5, at: start.addingTimeInterval(20))
    #expect(lowRan.count == 10)
    #expect(pick([sonnet, haikuMedium, haikuLow], lowRan, installed: [.claude], lineup: lineup)?.offer == haikuMedium)
}

// MARK: The cold

@Test func aWorkerThatDidBadlyIsLeftInTheColdTwiceAsLongEachTime() {
    let day: TimeInterval = 24 * 3600
    let lineup = Lineup(hard: [], normal: [grok46], easy: [])
    let proven = runs(grok46, 4, score: 5)
    func learner(_ bad: Int, after: TimeInterval) -> ModelCatalog.Offer? {
        // glm's bad runs end ten seconds after `start`, give or take.
        let history = proven + runs(glm, bad, score: 2, at: start) + runs(grok46, bad % 2, score: 5)
        return pick([grok46, glm], history, lineup: lineup, now: start.addingTimeInterval(after))?.offer
    }
    // One bad run: out for a day, then tried again.
    #expect(learner(1, after: day - 60) == grok46)
    #expect(learner(1, after: day + 60) == glm)
    // Bad again: two days. A third time: four.
    #expect(learner(2, after: 2 * day - 60) == grok46)
    #expect(learner(2, after: 2 * day + 60) == glm)
    #expect(learner(3, after: 4 * day - 60) == grok46)
    #expect(learner(3, after: 4 * day + 60) == glm)
}

@Test func aProvenWorkerOutsideTheLineupTakesThePieceWhenOverTwiceAsFast() {
    let lineup = Lineup(hard: [], normal: [grok46], easy: [])
    let slow = runs(grok46, 3, seconds: 300, score: 5)
    let fast = runs(glm, 4, seconds: 100, score: 5, at: start.addingTimeInterval(10))
    let choice = pick([grok46, glm], slow + fast, lineup: lineup)
    #expect(choice?.offer == glm)
    #expect(choice?.pick.code == .record)
    // Rated poorly, speed is not enough.
    let poor = runs(glm, 4, seconds: 100, score: 3, at: start.addingTimeInterval(10))
    #expect(pick([grok46, glm], slow + poor, lineup: lineup, now: start.addingTimeInterval(40 * 24 * 3600))?.offer == grok46)
}

// MARK: Known bad

@Test func knownBadOutsideTheLineupIsNeverPickedOnItsOwn() {
    let history = runs(haikuLow, 2, score: 2)
    #expect(pick([haikuLow], history, installed: [.claude]) == nil)
    #expect(pick([haikuLow, haikuMedium], history, installed: [.claude])?.offer == haikuMedium)
    #expect(pick([glm], runs(glm, 1, score: 3)) == nil)
    #expect(pick([glm], runs(glm, 1, score: 3) + runs(glm, 1, score: 5, at: start.addingTimeInterval(1)))?.offer == glm)
    // Two runs that delivered nothing rule a worker out too.
    #expect(pick([geminiLow, glm], runs(geminiLow, 2, failed: true))?.offer == glm)
}

// MARK: Eligibility

@Test func commandsKeepCursorAndGeminiOutOfTheChoice() {
    let all = [grokLow, geminiLow, haikuLow]
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
    let lineup = Lineup(hard: [], normal: [glm, grokLow], easy: [])
    let limit = runs(glm, 1, seconds: 5, failed: true, at: now.addingTimeInterval(-600))
    #expect(pick([glm, grokLow], limit, lineup: lineup)?.offer == grokLow)
    let other = runs(glm, 1, kind: .explore, seconds: 5, failed: true, at: now.addingTimeInterval(-600))
    #expect(pick([glm, grokLow], other, lineup: lineup)?.offer == grokLow)
    let old = runs(glm, 1, kind: .explore, seconds: 5, failed: true, at: now.addingTimeInterval(-31 * 60))
    #expect(pick([glm, grokLow], old, lineup: lineup)?.offer == glm)
    let slow = runs(glm, 1, kind: .explore, seconds: 90, failed: true, at: now.addingTimeInterval(-600))
    #expect(pick([glm, grokLow], slow, lineup: lineup)?.offer == glm)
    let recovered = other + runs(glm, 1, kind: .explore, seconds: 8, at: now.addingTimeInterval(-300))
    #expect(pick([glm, grokLow], recovered, lineup: lineup)?.offer == glm)
}

@Test func excludedAndUninstalledCLIsAreNotPicked() {
    #expect(pick([glm, grokLow], excluded: [.opencode])?.offer == grokLow)
    #expect(pick([glm, grokLow], installed: [.opencode])?.offer == glm)
    #expect(pick([glm, grokLow], installed: [.claude]) == nil)
    #expect(pick([], installed: installed) == nil)
}

@Test func aProvidersOwnWordsKeepItsCLIOutForAsLongAsTheKindSays() {
    let lineup = Lineup(hard: [], normal: [glm, grokLow], easy: [])
    func isOut(_ failure: ProviderFailure, endedMinutesAgo minutes: Double, kind: TaskKind = .explore) -> Bool {
        let started = now.addingTimeInterval(-minutes * 60 - 300)
        let history = runs(glm, 1, kind: kind, seconds: 300, failed: true, providerFailure: failure, at: started)
        return pick([glm, grokLow], history, lineup: lineup)?.offer == grokLow
    }
    let quota = ProviderFailure.quota("Free usage limit reached")
    #expect(isOut(quota, endedMinutesAgo: 59))
    #expect(isOut(quota, endedMinutesAgo: 59, kind: .review))
    #expect(!isOut(quota, endedMinutesAgo: 61))
    #expect(isOut(.unavailable("503 Service Unavailable"), endedMinutesAgo: 9))
    #expect(!isOut(.unavailable("503 Service Unavailable"), endedMinutesAgo: 11))
    let signedOut = ProviderFailure.signedOut("Authentication required")
    #expect(isOut(signedOut, endedMinutesAgo: 600))
    #expect(isOut(signedOut, endedMinutesAgo: 60 * 24 * 3))
}

@Test func aLaterRunThatWorkedLiftsAStallAndAQuickFailureWithWordsIsNotGuessedAt() {
    let lineup = Lineup(hard: [], normal: [glm, grokLow], easy: [])
    let failedLong = now.addingTimeInterval(-3 * 3600)
    let signedOut = runs(glm, 1, kind: .explore, seconds: 300, failed: true, providerFailure: .signedOut("Not logged in"), at: failedLong)
    #expect(pick([glm, grokLow], signedOut, lineup: lineup)?.offer == grokLow)
    #expect(pick([glm, grokLow], signedOut, lineup: lineup)?.pick.cause == .signedOut)
    let back = signedOut + runs(glm, 1, kind: .explore, seconds: 8, at: failedLong.addingTimeInterval(3600))
    #expect(pick([glm, grokLow], back, lineup: lineup)?.offer == glm)
    let stillOut = signedOut + runs(glm, 1, kind: .explore, seconds: 300, failed: true, at: failedLong.addingTimeInterval(3600))
    #expect(pick([glm, grokLow], stillOut, lineup: lineup)?.offer == grokLow)
    let blip = runs(glm, 1, kind: .explore, seconds: 5, failed: true, providerFailure: .unavailable("overloaded"), at: now.addingTimeInterval(-11 * 60))
    #expect(pick([glm, grokLow], blip, lineup: lineup)?.offer == glm)
    let unexplained = runs(glm, 1, kind: .explore, seconds: 5, failed: true, at: now.addingTimeInterval(-11 * 60))
    #expect(pick([glm, grokLow], unexplained, lineup: lineup)?.offer == grokLow)
}

// MARK: Circuit breaker

private func failures(_ worker: ModelCatalog.Offer, _ count: Int, kind: TaskKind = .explore, minutesAgo: Double) -> [Run] {
    runs(worker, count, kind: kind, seconds: 100, failed: true, at: now.addingTimeInterval(-minutesAgo * 60))
}

@Test func theBreakerCountsRunsOfAnyKindAndOnlyTheWorkerThatFailed() {
    let lineup = Lineup(hard: [], normal: [glm, grokLow], easy: [])
    let mixed = failures(glm, 1, kind: .explore, minutesAgo: 20)
        + failures(glm, 1, kind: .test, minutesAgo: 18)
        + failures(glm, 1, kind: .docs, minutesAgo: 16)
    #expect(pick([glm, grokLow], mixed, lineup: lineup)?.offer == grokLow)
    #expect(pick([glm], failures(glm, 3, minutesAgo: 20)) == nil)
    #expect(pick([glm, grokLow], failures(glm, 2, minutesAgo: 20), lineup: lineup)?.offer == glm)
    let low = failures(haikuLow, 3, minutesAgo: 20)
    #expect(pick([haikuLow, haikuHigh], low, installed: [.claude])?.offer == haikuHigh)
}

@Test func aSuccessClosesTheBreakerAndTimeExpiresIt() {
    let lineup = Lineup(hard: [], normal: [glm, grokLow], easy: [])
    let three = failures(glm, 3, minutesAgo: 20)
    #expect(pick([glm, grokLow], three + runs(glm, 1, kind: .explore, seconds: 8, at: now.addingTimeInterval(-5 * 60)), lineup: lineup)?.offer == glm)
    #expect(pick([glm, grokLow], failures(glm, 3, minutesAgo: 31 + 2), lineup: lineup)?.offer == glm)
    #expect(pick([glm, grokLow], failures(glm, 3, minutesAgo: 28 + 2), lineup: lineup)?.offer == grokLow)
    let spread = failures(glm, 1, minutesAgo: 50) + failures(glm, 1, minutesAgo: 30) + failures(glm, 1, minutesAgo: 10)
    #expect(pick([glm, grokLow], spread, lineup: lineup)?.offer == glm)
}

@Test func aProviderFailureOrAStoppedRunIsNeitherAFailureNorABreakInTheRow() {
    let quota = ProviderFailure.quota("Free usage limit reached")
    let provider = runs(glm, 1, kind: .explore, seconds: 100, failed: true, providerFailure: quota, at: now.addingTimeInterval(-9 * 60))
    #expect(WorkerPicker.resting(failures(glm, 2, minutesAgo: 20) + provider, now: now).isEmpty)
    #expect(WorkerPicker.resting(failures(glm, 3, minutesAgo: 20) + provider, now: now).count == 1)
    let stopped = Run(
        id: "0123abcd", spec: WorkerSpec(cli: .opencode, model: glm.model, prompt: "go", directory: "/tmp"),
        state: .cancelled, pid: 1, started: now.addingTimeInterval(-9 * 60), ended: now.addingTimeInterval(-8 * 60),
        output: nil, errorTail: nil
    )
    #expect(WorkerPicker.resting(failures(glm, 3, minutesAgo: 20) + [stopped], now: now).count == 1)
}

// MARK: agent_scores

@Test func agentScoresSaysWhoIsRestingAndPrintsTheLineupsWithDemotions() throws {
    let three = failures(glm, 3, minutesAgo: 20)
    let until = try #require(three.last?.ended).addingTimeInterval(30 * 60)
    let text = Scoreboard.summary(Scoreboard.scores(three), offers: [glm, grokLow], history: three, now: now)
    #expect(text.contains(
        "resting\n  opencode opencode/glm-5.3-flash-free — resting until \(WorkerPicker.clock(until)) after 3 failures in a row"
    ))
    #expect(!Scoreboard.summary(Scoreboard.scores(three), offers: [glm], history: three, now: now.addingTimeInterval(3600)).contains("resting"))

    let poor = runs(opus, 2, score: 3, difficulty: .hard)
    let lineups = Scoreboard.summary(Scoreboard.scores(poor), offers: catalogue, history: poor, now: now)
    #expect(lineups.contains(
        "  hard: 1. claude opus (low) [demoted: rated 3.0 on review], 2. claude sonnet (high), 3. claude haiku (high), 4. cursor grok-4.7-high-fast"
    ))
    #expect(lineups.contains("  easy: 1. cursor cursor-grok-4.6-low-fast, 2. opencode opencode/glm-5.3-flash-free, 3. claude haiku (low)"))
}

// MARK: Strength

@Test func strongWorkersAreSonnetOpusHaikuAtHighAndTheGroksAtHighOrXHigh() {
    for strong in [haikuHigh, sonnet, opus, grokHigh, offer(.cursor, "grok-4.7-xhigh-fast"), offer(.claude, "sonnet", "low")] {
        #expect(WorkerPicker.isStrong(strong), "\(strong.name)")
    }
    for light in [haikuLow, haikuMedium, grokLow, glm, geminiLow, offer(.opencode, "opencode/big-free", "high")] {
        #expect(!WorkerPicker.isStrong(light), "\(light.name)")
    }
}

@Test func outsideTheLineupAHardPieceGoesToStrongWorkersAndAnEasyOneStaysOffThem() {
    let all = [glm, haikuLow, haikuHigh, sonnet, opus, grokLow, grokHigh]
    #expect(pick(all, difficulty: .hard)?.offer == grokHigh)
    #expect(pick(all, installed: [.claude], difficulty: .hard)?.offer == haikuHigh)
    #expect(pick(all, installed: [.opencode], difficulty: .hard)?.offer == glm)
    #expect(pick([sonnet, haikuLow], difficulty: .easy)?.offer == haikuLow)
    #expect(pick([sonnet, grokHigh], difficulty: .easy)?.offer == grokHigh)
}

@Test func rankingUsesTheRunsOfTheSameDifficultyWhenAWorkerHasTwoOfThem() {
    let slowOnHard = runs(glm, 2, seconds: 5, score: 5, difficulty: .easy)
        + runs(glm, 2, seconds: 100, score: 5, difficulty: .hard, at: start.addingTimeInterval(10))
    let steady = runs(grokLow, 3, seconds: 20, score: 5, at: start.addingTimeInterval(20))
    let history = slowOnHard + steady
    #expect(pick([glm, grokLow], history, difficulty: .easy)?.offer == glm)
    #expect(pick([glm, grokLow], history, difficulty: .normal)?.offer == grokLow)
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

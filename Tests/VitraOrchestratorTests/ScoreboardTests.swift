import Foundation
import Testing
@testable import VitraOrchestrator

private let start = Date(timeIntervalSince1970: 1_000_000)

private func run(
    _ cli: WorkerCLI,
    _ model: String,
    seconds: TimeInterval = 10,
    state: Run.State = .finished(exitCode: 0),
    failed: Bool = false,
    cost: Double = 0,
    score: Int? = nil,
    kind: TaskKind? = nil,
    effort: String? = nil
) -> Run {
    Run(
        id: "0123abcd",
        spec: WorkerSpec(cli: cli, model: model, prompt: "go", directory: "/tmp", kind: kind, effort: effort),
        state: state,
        pid: 4242,
        started: start,
        ended: state == .running ? nil : start.addingTimeInterval(seconds),
        output: state == .running || state == .cancelled || state == .lost
            ? nil
            : WorkerOutput(text: failed ? "no" : "ok", isError: failed, costUSD: cost),
        errorTail: nil,
        rating: score.map { Rating(score: $0, note: nil, rated: start) }
    )
}

@Test func modelsAreRankedByTheQualityOfWhatTheyDelivered() {
    let scores = Scoreboard.scores([
        run(.opencode, "opencode/a-free", score: 3),
        run(.opencode, "opencode/a-free", score: 4),
        run(.gemini, "gemini-3.8-flash", score: 5),
        run(.gemini, "gemini-3.8-flash", score: 4),
        run(.claude, "haiku"),
    ])

    // The one that delivers well first; then the one nobody has judged, which
    // may yet be good; last the one already known to fall short.
    #expect(scores.map(\.model) == ["gemini-3.8-flash", "haiku", "opencode/a-free"])
    #expect(scores[0].averageScore == 4.5)
    #expect(scores[0].rated == 2)
    #expect(scores[1].averageScore == nil)
    #expect(scores[1].runs == 1)
    #expect(scores[2].averageScore == 3.5)
}

@Test func deliveryTimeIsTheMedianOfTheRunsThatDelivered() {
    let scores = Scoreboard.scores([
        run(.claude, "haiku", seconds: 4),
        run(.claude, "haiku", seconds: 6),
        run(.claude, "haiku", seconds: 200),
        // A failure's two seconds say nothing about how long a delivery takes.
        run(.claude, "haiku", seconds: 2, failed: true),
    ])
    #expect(scores.count == 1)
    #expect(scores[0].medianSeconds == 6)
    #expect(scores[0].runs == 4)
    #expect(scores[0].failures == 1)
}

@Test func runsThatNeverGotToDeliverAreNotHeldAgainstTheModel() {
    let scores = Scoreboard.scores([
        run(.claude, "haiku", state: .running),
        run(.claude, "haiku", state: .cancelled),
        run(.claude, "sonnet", state: .lost),
        run(.claude, "sonnet", cost: 0.25),
        run(.claude, "sonnet", cost: 0.5),
    ])
    // Still running or stopped by the user: no verdict either way.
    #expect(scores.map(\.model) == ["sonnet"])
    #expect(scores[0].runs == 3)
    #expect(scores[0].failures == 1)
    #expect(scores[0].costUSD == 0.75)
}

@Test func amongWorkersThatDeliverWellTheFastestComesFirstNotTheBestRated() {
    // Good enough is good enough: past that line what the user is waiting on
    // is the clock. A perfect answer in a minute loses to a good one in five
    // seconds.
    let scores = Scoreboard.scores([
        run(.claude, "sonnet", seconds: 60, score: 5, effort: "high"),
        run(.opencode, "opencode/fast-free", seconds: 5, score: 4),
        run(.gemini, "gemini-3.8-flash", seconds: 20, score: 4),
    ])
    #expect(scores.map(\.model) == ["opencode/fast-free", "gemini-3.8-flash", "sonnet"])
}

@Test func aFastWorkerThatOftenHasToBeRedoneIsNotFast() {
    // What counts is the time to a delivery that stands: one that fails half
    // the time takes, on average, two goes.
    let scores = Scoreboard.scores([
        run(.opencode, "opencode/steady-free", seconds: 6, score: 4),
        run(.opencode, "opencode/steady-free", seconds: 6, score: 5),
        run(.opencode, "opencode/flaky-free", seconds: 4, score: 5),
        run(.opencode, "opencode/flaky-free", seconds: 4, score: 5),
        run(.opencode, "opencode/flaky-free", seconds: 1, failed: true),
        run(.opencode, "opencode/flaky-free", seconds: 1, failed: true),
    ])
    // steady: 6s every time. flaky: 4s, but only one go in two delivers: 8s.
    #expect(scores.map(\.model) == ["opencode/steady-free", "opencode/flaky-free"])
    #expect(scores[0].expectedSeconds == 6)
    #expect(scores[1].expectedSeconds == 8)
}

@Test func theScoreboardReadsAsOneLinePerModel() {
    let text = Scoreboard.summary(Scoreboard.scores([
        run(.gemini, "gemini-3.8-flash", seconds: 8, score: 5),
        run(.gemini, "gemini-3.8-flash", seconds: 12, cost: 0.02, score: 4),
        run(.cursor, "grok-code-fast-1", seconds: 1, failed: true),
    ]))
    #expect(text == """
    Worker models by kind of task, best first (score is the average of your agent_rate ratings, 1 to 5):
    other
      gemini gemini-3.8-flash — 4.5/5 over 2 rated · 2 runs · 0 failed · median 10s · $0.02
      cursor grok-code-fast-1 — unrated · 1 run · 1 failed
    """)
    #expect(Scoreboard.summary([]) == "No worker has finished a run yet, so there is nothing to compare.")
}

@Test func aModelIsJudgedSeparatelyForEachKindOfTask() {
    // Good at reading code and bad at writing it are two different facts, and
    // one average would hide both.
    let runs = [
        run(.gemini, "gemini-3.8-flash", score: 5, kind: .explore),
        run(.gemini, "gemini-3.8-flash", score: 2, kind: .implement),
        run(.claude, "haiku", score: 4, kind: .implement),
        run(.claude, "haiku", score: 3, kind: .explore),
        // A run from before kinds existed, or one the orchestrator did not tag.
        run(.claude, "haiku", score: 5),
    ]

    let all = Scoreboard.scores(runs)
    #expect(all.map { "\($0.kind.rawValue) \($0.model)" } == [
        "explore gemini-3.8-flash", "explore haiku",
        "implement haiku", "implement gemini-3.8-flash",
        "other haiku",
    ])

    let implement = Scoreboard.scores(runs, kind: .implement)
    #expect(implement.map(\.model) == ["haiku", "gemini-3.8-flash"])

    #expect(Scoreboard.summary(Scoreboard.scores(runs, kind: .explore), kind: .explore) == """
    Worker models by kind of task, best first (score is the average of your agent_rate ratings, 1 to 5):
    explore
      gemini gemini-3.8-flash — 5.0/5 over 1 rated · 1 run · 0 failed · median 10s · $0.00
      claude haiku — 3.0/5 over 1 rated · 1 run · 1 failed · median 10s · $0.00
    """)
    #expect(Scoreboard.summary([], kind: .docs) == "No worker has finished a docs task yet, so there is nothing to compare.")
}

@Test func aRunRecordedBeforeKindsExistedStillLoads() throws {
    let old = #"{"cli":"claude","model":"haiku","prompt":"go","directory":"/tmp","access":"read"}"#
    let spec = try JSONDecoder().decode(WorkerSpec.self, from: Data(old.utf8))
    #expect(spec.kind == nil)
    #expect(spec.model == "haiku")
}

@Test func theSameModelAtTwoEffortsIsTwoWorkersWithTheirOwnRecords() {
    // Haiku at low is fast and shallow, at high slower and better: lumped
    // together, the record would describe a worker that does not exist.
    let scores = Scoreboard.scores([
        run(.claude, "haiku", seconds: 4, score: 3, effort: "low"),
        run(.claude, "haiku", seconds: 30, score: 5, effort: "high"),
        run(.claude, "haiku", seconds: 6, score: 3, effort: "low"),
    ])
    #expect(scores.map { "\($0.model) \($0.effort ?? "-") \($0.runs)" } == ["haiku high 1", "haiku low 2"])
    #expect(Scoreboard.summary(scores).contains("  claude haiku (high) — 5.0/5 over 1 rated · 1 run · 0 failed · median 30s"))
    #expect(Scoreboard.summary(scores).contains("  claude haiku (low) — 3.0/5 over 2 rated · 2 runs · 2 failed · median 5s"))
}

@Test func aDeliveryThatDidNotDoWhatWasAskedIsAFailureEvenThoughItRan() {
    // The worker ran, exited clean and said it was done. It was not what was
    // asked for. That is the failure that matters, more than a crash.
    let scores = Scoreboard.scores([
        run(.claude, "haiku", seconds: 5, score: 5),
        run(.claude, "haiku", seconds: 7, score: 4),
        run(.claude, "haiku", seconds: 9, score: 3),
        run(.claude, "haiku", seconds: 9, score: 1),
        run(.claude, "haiku", seconds: 2, failed: true),
        // Not rated yet: no verdict, so not a failure.
        run(.claude, "haiku", seconds: 6),
    ])
    #expect(scores.count == 1)
    #expect(scores[0].runs == 6)
    // Rated below 4 twice, and one that never delivered at all.
    #expect(scores[0].failures == 3)
    #expect(Rating(score: 4, note: nil, rated: start).isSatisfactory)
    #expect(!Rating(score: 3, note: nil, rated: start).isSatisfactory)
}

@Test func aCheapFastWorkerThatDoesWellComesBeforeADearOneThatDoesALittleBetter() {
    let scores = Scoreboard.scores([
        run(.claude, "sonnet", seconds: 60, cost: 0.80, score: 5, kind: .implement, effort: "high"),
        run(.claude, "haiku", seconds: 40, cost: 0.05, score: 4, kind: .implement, effort: "low"),
        // Faster still, but a dollar a go: a minute's worth of waiting.
        run(.opencode, "opencode/a-free", seconds: 30, cost: 1.00, score: 4, kind: .implement),
    ])
    #expect(scores.map(\.model) == ["haiku", "opencode/a-free", "sonnet"])
}

@Test func theUntriedLineNamesTheOfferedWorkersWithNoRunOnThatKind() {
    let offers = [
        ModelCatalog.Offer(cli: .cursor, model: "cursor-grok-4.5-low-fast", effort: nil),
        ModelCatalog.Offer(cli: .cursor, model: "cursor-grok-4.6-medium-fast", effort: nil),
        ModelCatalog.Offer(cli: .claude, model: "haiku", effort: "high"),
    ]
    let history = [
        run(.cursor, "cursor-grok-4.6-medium-fast", kind: .review),
        // A run of another kind is no try at review.
        run(.claude, "haiku", kind: .explore, effort: "high"),
    ]

    #expect(Scoreboard.untriedLine(offers, history: history, kind: .review)
        == "  not tried yet: cursor cursor-grok-4.5-low-fast, claude haiku (high)")
    #expect(Scoreboard.untriedLine(offers, history: history, kind: .explore)
        == "  not tried yet: cursor cursor-grok-4.5-low-fast, cursor cursor-grok-4.6-medium-fast, claude haiku (high)")
    #expect(Scoreboard.untriedLine([], history: history, kind: .review) == nil)
}

@Test func theUntriedLineCapsItsNamesAndCountsTheRest() {
    let offers = (1...17).map { ModelCatalog.Offer(cli: .cursor, model: "grok-\($0)", effort: nil) }
    let line = Scoreboard.untriedLine(offers, history: [], kind: .review)

    #expect(line?.hasSuffix(", grok-15, and 2 more") == true)
    #expect(line?.contains("grok-16") == false)
}

@Test func theSummaryPlacesTheUntriedLineUnderItsKind() {
    let history = [run(.claude, "haiku", score: 5, kind: .review, effort: "low")]
    let offers = [ModelCatalog.Offer(cli: .opencode, model: "opencode/glm-5.3-flash-free", effort: nil)]
    let text = Scoreboard.summary(Scoreboard.scores(history, kind: .review), kind: .review, offers: offers, history: history)

    #expect(text == """
    Worker models by kind of task, best first (score is the average of your agent_rate ratings, 1 to 5):
    review
      claude haiku (low) — 5.0/5 over 1 rated · 1 run · 0 failed · median 10s · $0.00
      not tried yet: opencode opencode/glm-5.3-flash-free
    """)
}

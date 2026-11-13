import AppKit
import Foundation
import Testing
@testable import VitraApp
@testable import VitraOrchestrator

private let start = Date(timeIntervalSince1970: 1_000_000)
private typealias Offer = ModelCatalog.Offer

private let haikuLow = Offer(cli: .claude, model: "haiku", effort: "low")
private let haikuHigh = Offer(cli: .claude, model: "haiku", effort: "high")
private let sonnet = Offer(cli: .claude, model: "sonnet", effort: "high")
private let grokLow = Offer(cli: .cursor, model: "grok-4.7-low-fast", effort: nil)
private let grokHigh = Offer(cli: .cursor, model: "grok-4.7-high-fast", effort: nil)
private let glm = Offer(cli: .opencode, model: "opencode/glm-5.3-flash-free", effort: nil)

/// One run of `worker`: delivered unless said otherwise.
private func run(
    _ worker: Offer, kind: TaskKind = .implement, difficulty: Difficulty? = nil, score: Int? = nil,
    seconds: TimeInterval = 60, cost: Double = 0, state: Run.State = .finished(exitCode: 0), isError: Bool = false,
    providerFailure: ProviderFailure? = nil, ago: TimeInterval = 0
) -> Run {
    let started = start.addingTimeInterval(-ago)
    var hasOutput = false
    if case .finished = state { hasOutput = true }
    return Run(
        id: UUID().uuidString,
        spec: WorkerSpec(cli: worker.cli, model: worker.model, prompt: "x", directory: "/w", kind: kind,
                         effort: worker.effort, difficulty: difficulty),
        state: state, pid: 1, started: started, ended: state == .running ? nil : started.addingTimeInterval(seconds),
        output: hasOutput ? WorkerOutput(text: "ok", isError: isError, costUSD: cost) : nil, errorTail: nil,
        rating: score.map { Rating(score: $0, note: nil, rated: started) },
        providerFailure: providerFailure
    )
}

private func names(_ group: RankingGroup) -> [String] { group.rows.map(\.name) }

// MARK: - Grouping

@Test func eachGroupingGathersTheRowsIntoItsOwnTables() {
    let runs = [
        run(haikuLow, kind: .explore, difficulty: .easy, score: 5),
        run(sonnet, kind: .implement, difficulty: .hard, score: 4),
        run(grokLow, kind: .review, score: 4),
        run(glm, kind: .review, difficulty: .easy, score: 3),
    ]
    func titles(_ grouping: RankingGrouping) -> [String] {
        RankingSlice.make(runs: runs, offers: nil, options: RankingOptions(grouping: grouping)).groups.map(\.title)
    }
    // In their usual order, and only those with runs.
    #expect(titles(.kind) == ["explorar", "revisar", "implementar"])
    #expect(titles(.difficulty) == ["Difícil", "Normal", "Fácil"])
    #expect(titles(.provider) == ["claude", "opencode", "cursor"])
    #expect(titles(.model) == ["claude · haiku", "claude · sonnet", "opencode · glm-5.3-flash-free", "cursor · grok-4.7-fast"])
    #expect(titles(.none) == ["todos"])

    let byDifficulty = RankingSlice.make(runs: runs, offers: nil, options: RankingOptions(grouping: .difficulty))
    // A run with no difficulty is a normal piece.
    #expect(names(byDifficulty.groups[1]) == ["grok-4.7-low-fast"])
    #expect(Set(names(byDifficulty.groups[2])) == ["haiku (low)", "glm-5.3-flash-free"])
    #expect(byDifficulty.groups[2].totals == "2 operários · 1 entrega")
}

@Test func theEffortIsPartOfTheWorkerAndGroupingByModelPutsTheEffortsTogether() {
    let runs = [run(haikuLow, score: 5), run(haikuHigh, score: 4), run(grokLow, score: 5), run(grokHigh, score: 3)]
    let general = RankingSlice.make(runs: runs, offers: nil, options: RankingOptions(grouping: .none))
    // Four workers, not two models.
    // Ties on rating, time and uses go by name.
    #expect(names(general.groups[0]) == ["grok-4.7-low-fast", "haiku (low)", "haiku (high)", "grok-4.7-high-fast"])

    let byModel = RankingSlice.make(runs: runs, offers: nil, options: RankingOptions(grouping: .model))
    #expect(byModel.groups.map(\.title) == ["claude · haiku", "cursor · grok-4.7-fast"])
    // The table says the model; a row is its effort.
    #expect(names(byModel.groups[0]) == ["low", "high"])
    #expect(names(byModel.groups[1]) == ["low", "high"])
}

// MARK: - Aggregation

@Test func aRowAcrossKindsAveragesEveryRatingAndTakesItsMediansOverTheDeliveredRuns() throws {
    let runs = [
        run(sonnet, kind: .explore, score: 5, seconds: 10, cost: 0.10),
        run(sonnet, kind: .implement, score: 4, seconds: 30, cost: 0.30),
        run(sonnet, kind: .review, score: 3, seconds: 900, cost: 9), // rated below satisfactory: not delivered
        run(sonnet, kind: .test, seconds: 2, cost: 0.01, state: .finished(exitCode: 1), isError: true),
        run(sonnet, kind: .test, state: .lost),
        run(sonnet, kind: .docs, state: .running),
        run(sonnet, kind: .docs, state: .cancelled),
        run(sonnet, kind: .docs, providerFailure: .quota("x")),
    ]
    let row = RankingSlice.make(runs: runs, offers: nil, options: RankingOptions(grouping: .none)).groups[0].rows[0]
    let figures = try #require(row.figures)
    // Every time it was sent, running and stopped ones included; not the
    // run its provider refused.
    #expect(figures.uses == 7)
    // Delivered of those that came to a verdict.
    #expect(figures.attempted == 5)
    #expect(figures.delivered == 2)
    #expect(figures.deliveriesText == "2/5")
    #expect(figures.rating == 4)
    #expect(figures.scoreText == "4.0")
    #expect(figures.medianSeconds == 20)
    #expect(figures.timeText == "20s")
    #expect(abs((figures.medianCost ?? 0) - 0.2) < 1e-9)
    #expect(figures.costText == "$0.20")
}

@Test func aProviderFailureIsNoUseAndAWorkerWithOnlyThoseCountsAsNeverUsed() {
    let runs = [run(sonnet, score: 5), run(grokLow, providerFailure: .signedOut("x"))]
    let slice = RankingSlice.make(runs: runs, offers: [sonnet, grokLow], options: RankingOptions(grouping: .none, showsUnused: true))
    #expect(slice.groups[0].rows.map(\.name) == ["sonnet (high)", "grok-4.7-low-fast"])
    #expect(slice.groups[0].rows[1].figures == nil)
    #expect(slice.unusedCount == 1)
}

// MARK: - Ordering

@Test func eachOrderingRanksTheRowsAndBreaksTiesAndTurnsAround() {
    let runs = [
        run(haikuLow, score: 4, seconds: 30, cost: 0.01), run(haikuLow, score: 4, seconds: 30, cost: 0.01),
        run(haikuLow, score: 4, seconds: 30, cost: 0.01),
        run(sonnet, score: 5, seconds: 200, cost: 0.20),
        run(grokLow, score: 4, seconds: 50, cost: 0.02), run(grokLow, state: .finished(exitCode: 1), isError: true),
        run(glm, seconds: 10), // never rated
    ]
    func order(_ order: RankingOrder, reversed: Bool = false) -> [String] {
        let options = RankingOptions(grouping: .none, order: order, isReversed: reversed)
        return names(RankingSlice.make(runs: runs, offers: nil, options: options).groups[0])
    }
    // Rating, best first; a tie goes to the faster; no rating comes last.
    #expect(order(.rating) == ["sonnet (high)", "haiku (low)", "grok-4.7-low-fast", "glm-5.3-flash-free"])
    // Reversed, the worst rated first — and the unrated still last.
    #expect(order(.rating, reversed: true) == ["haiku (low)", "grok-4.7-low-fast", "sonnet (high)", "glm-5.3-flash-free"])
    #expect(order(.time) == ["glm-5.3-flash-free", "haiku (low)", "grok-4.7-low-fast", "sonnet (high)"])
    #expect(order(.time, reversed: true) == ["sonnet (high)", "grok-4.7-low-fast", "haiku (low)", "glm-5.3-flash-free"])
    // Uses: grok's failure is a use; the tie between sonnet and glm goes to the rated one.
    #expect(order(.uses) == ["haiku (low)", "grok-4.7-low-fast", "sonnet (high)", "glm-5.3-flash-free"])
    #expect(order(.deliveries) == ["haiku (low)", "sonnet (high)", "glm-5.3-flash-free", "grok-4.7-low-fast"])
    #expect(order(.cost) == ["glm-5.3-flash-free", "haiku (low)", "grok-4.7-low-fast", "sonnet (high)"])
    #expect(order(.name) == ["glm-5.3-flash-free", "grok-4.7-low-fast", "haiku (low)", "sonnet (high)"])
    #expect(order(.name, reversed: true) == ["sonnet (high)", "haiku (low)", "grok-4.7-low-fast", "glm-5.3-flash-free"])

    // Places restart in every table and follow the ordering.
    let byProvider = RankingSlice.make(runs: runs, offers: nil, options: RankingOptions(grouping: .provider, order: .time))
    #expect(byProvider.groups.map { $0.rows.compactMap(\.place) } == [[1, 2], [1], [1]])
}

@Test func clickingAColumnHeadRanksByItAndClickingAgainTurnsItAround() {
    let options = RankingOptions()
    #expect(options.order == .rating && !options.isAscending)
    let byTime = options.clicking(.time)
    #expect(byTime.order == .time && !byTime.isReversed && byTime.isAscending)
    let reversed = byTime.clicking(.time)
    #expect(reversed.isReversed && !reversed.isAscending)
    #expect(reversed.clicking(.uses) == RankingOptions(order: .uses))
}

@Test func theChoicesAreRememberedInUserDefaults() throws {
    let suite = "vitra-ranking-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(RankingOptions.load(from: defaults) == RankingOptions())
    let chosen = RankingOptions(grouping: .provider, order: .cost, isReversed: true, showsUnused: true)
    chosen.save(to: defaults)
    #expect(RankingOptions.load(from: defaults) == chosen)
}

// MARK: - Never used

@Test func unusedWorkersEndEachTableOnlyWhenAskedAndNeverWhenTheyRanThere() {
    let runs = [run(haikuLow, kind: .explore, score: 5), run(sonnet, kind: .implement, score: 4)]
    let offers = [haikuLow, haikuHigh, sonnet, grokLow]
    let off = RankingSlice.make(runs: runs, offers: offers, options: RankingOptions())
    #expect(off.groups.flatMap(\.rows).allSatisfy { $0.figures != nil })
    #expect(off.unusedCount == 2)

    let on = RankingSlice.make(runs: runs, offers: offers, options: RankingOptions(showsUnused: true))
    // Every kind now has a table: the catalogue's workers are unused in it.
    #expect(on.groups.count == TaskKind.allCases.count)
    let explore = on.groups[0]
    #expect(explore.title == "explorar")
    #expect(names(explore) == ["haiku (low)", "haiku (high)", "sonnet (high)", "grok-4.7-low-fast"])
    #expect(explore.rows.map { $0.place } == [1, nil, nil, nil])
    for group in on.groups {
        // Once per table, and never beside its own record.
        #expect(Set(group.rows.map(\.worker)).count == group.rows.count)
        #expect(group.rows.filter { $0.figures != nil }.allSatisfy { used in
            !group.rows.contains { $0.figures == nil && $0.worker == used.worker }
        })
    }
    // By provider, a table takes only its provider's workers.
    let byProvider = RankingSlice.make(runs: runs, offers: offers, options: RankingOptions(grouping: .provider, showsUnused: true))
    #expect(byProvider.groups.map(\.title) == ["claude", "cursor"])
    #expect(names(byProvider.groups[1]) == ["grok-4.7-low-fast"])

    // No grouping, by uses: the whole list from most used to never used.
    let all = RankingSlice.make(runs: runs + [run(sonnet, score: 5)], offers: offers,
                                options: RankingOptions(grouping: .none, order: .uses, showsUnused: true))
    #expect(names(all.groups[0]) == ["sonnet (high)", "haiku (low)", "haiku (high)", "grok-4.7-low-fast"])
}

@Test func anEmptyHistoryWithACatalogueIsAllNeverUsedAndAnEmptyCatalogueAddsNothing() {
    let offers = [haikuLow, grokLow]
    let empty = RankingSlice.make(runs: [], offers: offers, options: RankingOptions(grouping: .none, showsUnused: true))
    #expect(empty.groups.count == 1)
    #expect(empty.groups[0].rows.allSatisfy { $0.figures == nil && $0.place == nil })
    #expect(empty.summary == "2 operários · 0 usados · 2 nunca usados · 0 entregas")
    #expect(RankingSlice.make(runs: [], offers: offers, options: RankingOptions()).groups.isEmpty)

    let noCatalogue = RankingSlice.make(runs: [run(haikuLow, score: 5)], offers: [], options: RankingOptions(showsUnused: true))
    #expect(noCatalogue.groups.map(names) == [["haiku (low)"]])
    #expect(noCatalogue.unusedCount == 0)
    #expect(RankingSlice.make(runs: [], offers: [], options: RankingOptions(showsUnused: true)).groups.isEmpty)
}

// MARK: - Summary and breakdown

@Test func theSummaryCountsTheWorkersTheUsedTheNeverUsedAndTheDeliveries() {
    let runs = [run(haikuLow, score: 5), run(haikuLow, score: 2), run(sonnet, score: 4), run(grokLow, providerFailure: .quota("x"))]
    #expect(RankingSlice.summary(runs: runs, offers: [haikuLow, grokLow, glm])
        == "4 operários · 2 usados · 2 nunca usados · 2 entregas")
    // A worker the catalogue no longer offers still counts as one.
    #expect(RankingSlice.summary(runs: [run(sonnet, score: 5)], offers: [haikuLow])
        == "2 operários · 1 usado · 1 nunca usado · 1 entrega")
    // Before the catalogue is listed, only what the runs say.
    #expect(RankingSlice.summary(runs: runs, offers: nil) == "2 usados · 2 entregas")
}

@Test func aWorkersBreakdownCutsItsRecordByKindAndByDifficulty() {
    let runs = [
        run(sonnet, kind: .review, difficulty: .hard, score: 5, ago: 60),
        run(sonnet, kind: .review, score: 3, ago: 30),
        run(sonnet, kind: .explore, difficulty: .easy, score: 4),
        run(haikuLow, kind: .test, score: 5),
    ]
    let breakdown = RankingBreakdown.of(sonnet, runs: runs)
    #expect(breakdown.overall.uses == 3)
    #expect(breakdown.overall.lastUsed == start)
    #expect(breakdown.kinds.map(\.title) == ["explorar", "revisar"])
    #expect(breakdown.kinds[1].figures.rating == 4)
    #expect(breakdown.difficulties.map(\.title) == ["difícil", "normal", "fácil"])
    #expect(RankingBreakdown.of(glm, runs: runs).kinds.isEmpty)
}

// MARK: - The view

@Test @MainActor func theRankingDrawsItsControlsItsTablesAndSaysSoWhenThereIsNothingYet() {
    _ = NSApplication.shared
    func texts(_ view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }
    let history = [run(haikuLow, kind: .explore, score: 5), run(sonnet, kind: .implement, score: 4)]
    let data = RankingData(lineup: .standard, history: history, offers: [haikuLow, sonnet, grokLow], demoted: [])
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-lineup-\(UUID().uuidString).json")
    let view = RankingView(lineup: LineupSectionView(file: file), loader: { done in MainActor.assumeIsolated { done(data) } },
                           defaults: nil, options: RankingOptions(), computesInline: true)
    view.reload()
    let shown = texts(view)
    #expect(shown.contains("RANKING"))
    #expect(shown.contains("3 operários · 2 usados · 1 nunca usado · 2 entregas"))
    #expect(shown.contains("haiku (low)") && shown.contains("sonnet (high)"))
    #expect(view.slice?.groups.map(\.title) == ["explorar", "implementar"])

    let empty = RankingData(lineup: .standard, history: [], offers: [], demoted: [])
    let nothing = RankingView(lineup: LineupSectionView(file: file), loader: { done in MainActor.assumeIsolated { done(empty) } },
                              defaults: nil, options: RankingOptions(), computesInline: true)
    nothing.reload()
    #expect(texts(nothing).contains("Ainda não há entregas para comparar"))
    #expect(!texts(nothing).contains("RANKING"))
}

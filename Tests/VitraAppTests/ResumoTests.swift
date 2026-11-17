import Foundation
import Testing
@testable import VitraApp
import VitraOrchestrator

// MARK: - Fixtures

private let project = "/work/vitra"
/// Wednesday 11 November 2026, 16:00 UTC.
private let now = Date(timeIntervalSince1970: 1_794_412_800)
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func run(
    _ id: String, cli: WorkerCLI = .claude, model: String = "opus", effort: String? = "low",
    label: String? = "Tarefa", kind: TaskKind = .implement, state: Run.State = .finished(exitCode: 0),
    ago: TimeInterval, took: TimeInterval = 60, cost: Double = 0, tokens: Int = 0, score: Int? = nil,
    note: String? = nil, isError: Bool = false, answer: String = "ok", difficulty: Difficulty? = nil,
    project owner: String = project, providerFailure: ProviderFailure? = nil, redoOf: String? = nil,
    retryOf: String? = nil, pick: PickReason? = nil
) -> Run {
    let started = now.addingTimeInterval(-ago)
    let finished: Bool = if case .finished = state { true } else { false }
    return Run(
        id: id,
        spec: WorkerSpec(
            cli: cli, model: model, prompt: label ?? "tarefa", directory: owner, label: label, kind: kind,
            effort: effort, project: owner, difficulty: difficulty
        ),
        state: state,
        pid: nil,
        started: started,
        ended: state == .running ? nil : started.addingTimeInterval(took),
        output: finished ? WorkerOutput(text: answer, isError: isError, costUSD: cost, inputTokens: tokens, outputTokens: 0) : nil,
        errorTail: nil,
        rating: score.map { Rating(score: $0, note: note, rated: started) },
        providerFailure: providerFailure,
        wasPicked: pick != nil,
        pick: pick,
        retryOf: retryOf,
        redoOf: redoOf
    )
}

private func audit(_ id: String, of label: String, verdict: String, ago: TimeInterval, took: TimeInterval = 60, model: String = "grok") -> Run {
    run(id, cli: .cursor, model: model, effort: nil, label: "auditoria: " + label, kind: .review, ago: ago, took: took, answer: verdict + "\n- detalhe")
}

// MARK: - Totals

@Test func totalsCountCostTokensDeliveriesAndFailuresFromAStart() {
    let runs = [
        run("a", ago: 3_600, cost: 0.5, tokens: 1_000),
        run("b", cli: .opencode, ago: 7_200, cost: 0, tokens: 4_000), // free, tokens still count
        run("c", state: .finished(exitCode: 1), ago: 600, cost: 0.1, isError: true),
        run("d", state: .lost, ago: 300),
        run("e", state: .running, ago: 60),
        run("f", ago: 3 * 86_400, cost: 9),
    ]
    let today = Resumo.totals(runs, from: utc.startOfDay(for: now))
    #expect(today == SpendTotals(cost: 0.6, tokens: 5_000, deliveries: 2, failures: 2))
    #expect(Resumo.totals(runs, from: now.addingTimeInterval(-4 * 86_400)).cost == 9.6)
    #expect(Resumo.countsText(today) == "2 entregas · 2 falhas")
    #expect(Resumo.countsText(SpendTotals(deliveries: 1)) == "1 entrega")
}

@Test func theResumoSplitsThisProjectFromAllOfThem() {
    let runs = [
        run("mine", ago: 600, cost: 1),
        run("old", ago: 2 * 86_400, cost: 2),
        run("theirs", ago: 600, cost: 4, project: "/work/hapto"),
    ]
    let resumo = Resumo.make(runs: runs, project: CockpitProject(path: project), usage: nil, now: now, calendar: utc)
    #expect(resumo.today.cost == 1)
    #expect(resumo.week.cost == 3)
    #expect(resumo.allToday.cost == 5)
    #expect(resumo.allWeek.cost == 7)
    #expect(resumo.trabalhos.map(\.id) == ["mine", "old"])
    #expect(resumo.subscription == nil)
}

// MARK: - Providers

@Test func providerRowsCountTodaysDeliveriesCostAndMedian() {
    let runs = [
        run("a", ago: 600, took: 60, cost: 0.2),
        run("b", ago: 1_200, took: 180, cost: 0.3),
        run("c", ago: 1_800, took: 120, cost: 0.1),
        run("x", ago: 2 * 86_400, took: 10, cost: 5),
    ]
    let rows = Resumo.providerRows(runs, now: now, calendar: utc)
    #expect(rows.map(\.cli) == WorkerCLI.allCases)
    let claude = rows[0]
    #expect(claude.deliveries == 3)
    #expect(abs(claude.cost - 0.6) < 0.0001)
    #expect(claude.medianSeconds == 120)
    #expect(claude.availability == .ok)
    #expect(rows[1].medianSeconds == nil)
}

@Test func availabilityFollowsTheProvidersWordsOnItsLatestRun() {
    let quota = run("q", cli: .opencode, ago: 600, took: 4, providerFailure: .quota("usage limit"))
    let ended = quota.ended!
    #expect(Resumo.availability(.opencode, runs: [quota], resting: [:], now: now) == .noQuota(until: ended.addingTimeInterval(3_600)))
    #expect(Resumo.availabilityText(.noQuota(until: ended.addingTimeInterval(3_600)), calendar: utc) == "sem cota · volta ~16:50")

    let down = run("d", cli: .opencode, ago: 300, took: 2, providerFailure: .unavailable("503"))
    #expect(Resumo.availability(.opencode, runs: [down], resting: [:], now: now) == .down(until: down.ended!.addingTimeInterval(600)))

    // A limit long past is over; a later run that delivered closes it too.
    let stale = run("s", cli: .opencode, ago: 2 * 3_600, providerFailure: .quota("quota"))
    #expect(Resumo.availability(.opencode, runs: [stale], resting: [:], now: now) == .ok)
    #expect(Resumo.availability(.opencode, runs: [quota, run("ok", cli: .opencode, ago: 60)], resting: [:], now: now) == .ok)

    let signedOut = run("o", cli: .gemini, ago: 5 * 3_600, providerFailure: .signedOut("please log in"))
    #expect(Resumo.availability(.gemini, runs: [signedOut], resting: [:], now: now) == .signedOut)
    #expect(Resumo.availabilityText(.signedOut, calendar: utc) == "deslogado")
}

@Test func aProviderWithAWorkerOnTheCircuitBreakerIsResting() {
    let failures = [20.0, 14, 8].enumerated().map { index, minutes in
        run("f\(index)", cli: .cursor, model: "grok-4.7-low-fast", effort: nil, ago: minutes * 60, took: 30, isError: true)
    }
    let rows = Resumo.providerRows(failures, now: now, calendar: utc)
    let cursor = rows.first { $0.cli == .cursor }!
    guard case let .resting(until, workers) = cursor.availability else {
        Issue.record("cursor should be resting, is \(cursor.availability)")
        return
    }
    #expect(workers == ["grok-4.7-low-fast"])
    #expect(until == failures[2].ended!.addingTimeInterval(30 * 60))
    #expect(Resumo.availabilityText(cursor.availability, calendar: utc).hasPrefix("descansando até "))
}

@Test func subscriptionBarsAreShownFreshAndColouredByLevel() {
    let fresh = SubscriptionUsage(sevenDay: 87, fiveHour: 18, updated: now.addingTimeInterval(-60))
    #expect(Resumo.subscriptionBars(fresh, now: now) == SubscriptionBars(week: 87, fiveHour: 18))
    #expect(Resumo.subscriptionBars(SubscriptionUsage(sevenDay: 87, fiveHour: nil, updated: now.addingTimeInterval(-49 * 3_600)), now: now) == nil)
    #expect(Resumo.subscriptionBars(SubscriptionUsage(sevenDay: nil, fiveHour: nil, updated: now), now: now) == nil)
    #expect(SubscriptionBars.level(79) == .calm)
    #expect(SubscriptionBars.level(80) == .warm)
    #expect(SubscriptionBars.level(95) == .hot)
}

// MARK: - Sparkline

@Test func theSparklineHasSevenDaysOldestFirstWithEmptyDaysAtZero() {
    let runs = [
        run("t", ago: 3_600, cost: 0.5),
        run("t2", ago: 7_200, cost: 0.25),
        run("y3", ago: 3 * 86_400, cost: 2),
        run("old", ago: 9 * 86_400, cost: 50),
    ]
    let days = Resumo.dailyCost(runs, now: now, calendar: utc)
    #expect(days.count == 7)
    #expect(days.last?.day == utc.startOfDay(for: now))
    #expect(days.map(\.cost) == [0, 0, 0, 2, 0, 0, 0.75])
    #expect(Resumo.peak(days) == 3)
    #expect(Resumo.peak(Resumo.dailyCost([], now: now, calendar: utc)) == nil)
    #expect(Resumo.weekday(now, calendar: utc) == "qua")
}

// MARK: - Grouping

@Test func aDeliveryItsAuditsItsRedosAndItsFailoverAreOneTrabalho() {
    let runs = [
        run("d1", label: "Cache", ago: 5_000, took: 300, cost: 0.4, score: 3),
        audit("a1", of: "Cache", verdict: "ship after fixes", ago: 4_600),
        run("r1", model: "sonnet", effort: "high", label: "Cache", ago: 4_000, took: 400, cost: 0.6, score: 5, redoOf: "d1"),
        audit("a2", of: "Cache", verdict: "ship", ago: 3_500),
        run("r2", label: "Cache", ago: 3_000, took: 100, cost: 0.1, score: 4, redoOf: "r1"),
        run("q1", cli: .opencode, model: "glm", effort: nil, label: "Lista", state: .finished(exitCode: 1), ago: 2_000, took: 4,
            isError: true, providerFailure: .quota("usage limit")),
        run("f1", model: "haiku", label: "Lista", ago: 1_990, took: 200, score: 5, retryOf: "q1"),
        audit("orphan", of: "Algo de antes", verdict: "ship", ago: 1_000),
    ]
    let trabalhos = Trabalho.group(runs)
    #expect(trabalhos.map(\.id) == ["orphan", "q1", "d1"])

    let cache = trabalhos[2]
    #expect(cache.steps.map(\.run.id) == ["d1", "a1", "r1", "a2", "r2"])
    #expect(cache.steps.map(\.role) == [.delivery, .audit, .redo, .audit, .redo])
    #expect(cache.outcome == .delivered(score: 4, redos: 2))
    #expect(cache.outcomeText == "refeito 2x e entregue 4/5")
    #expect(cache.chain == "opus (low) ✗ → auditoria grok ! → refeito sonnet (high) ✓ → auditoria grok ✓ → refeito opus (low) ✓")
    #expect(abs(cache.cost - 1.1) < 0.0001)
    #expect(cache.duration(now: now) == 5_000 - 3_000 + 100)

    let lista = trabalhos[1]
    #expect(lista.steps.map(\.role) == [.delivery, .retry])
    #expect(lista.outcomeText == "entregue 5/5")
    #expect(lista.chain == "glm ✗ → failover haiku (low) ✓")
    #expect(lista.steps[0].failure == "provedor: usage limit")

    // An audit whose delivery was never read stands alone, under its own label.
    #expect(trabalhos[0].title == "auditoria: Algo de antes")
    #expect(trabalhos[0].steps.map(\.role) == [.audit])
}

@Test func aRedoWhoseOriginalWasNotReadStartsItsOwnTrabalho() {
    let trabalhos = Trabalho.group([run("r", label: "Cache", ago: 60, redoOf: "gone")])
    #expect(trabalhos.map(\.id) == ["r"])
    #expect(trabalhos[0].steps[0].role == .redo)
}

@Test func outcomesAreRunningDeliveredFailedOrDiscarded() {
    func outcome(_ runs: [Run]) -> Trabalho.Outcome { Trabalho.group(runs)[0].outcome }
    #expect(outcome([run("a", state: .running, ago: 60)]) == .running)
    #expect(outcome([run("a", ago: 60, score: 5)]) == .delivered(score: 5, redos: 0))
    #expect(outcome([run("a", ago: 60)]) == .delivered(score: nil, redos: 0))
    #expect(outcome([run("a", state: .finished(exitCode: 1), ago: 60, isError: true)]) == .failed)
    #expect(outcome([run("a", state: .lost, ago: 60)]) == .failed)
    #expect(outcome([run("a", state: .cancelled, ago: 60)]) == .discarded)
    #expect(outcome([run("a", ago: 60, score: 2)]) == .discarded)
    // An audit after the delivery does not decide its outcome.
    #expect(outcome([run("a", ago: 600, score: 5), audit("b", of: "Tarefa", verdict: "do not ship", ago: 300)]) == .delivered(score: 5, redos: 0))
    #expect(Trabalho.group([run("a", state: .cancelled, ago: 60)])[0].outcomeText == "descartado")
    #expect(Trabalho.group([run("a", state: .lost, ago: 60)])[0].outcomeText == "falhou")
}

@Test func auditVerdictsAreReadFromTheFirstLine() {
    #expect(AuditVerdict(audit("a", of: "x", verdict: "ship", ago: 1)) == .ship)
    #expect(AuditVerdict(audit("a", of: "x", verdict: "**Ship after fixes**", ago: 1)) == .fixes)
    #expect(AuditVerdict(audit("a", of: "x", verdict: "`do not ship`", ago: 1)) == .block)
    #expect(AuditVerdict(audit("a", of: "x", verdict: "looks fine", ago: 1)) == nil)
}

// MARK: - Facts

@Test func theHardPiecesFactNeedsThreeOfEach() {
    var runs = (0..<4).map { run("o\($0)", ago: Double($0 + 1) * 3_600, score: $0 == 0 ? 2 : 5, difficulty: .hard) }
    runs += (0..<3).map { run("s\($0)", model: "sonnet", effort: "high", ago: Double($0 + 1) * 3_600, score: 5, difficulty: .hard) }
    #expect(Retrospective.hardFact(runs) == "opus (low) entregou 3 de 4 difíceis; sonnet (high), 3 de 3.")
    #expect(Retrospective.hardFact(Array(runs.prefix(4))) == "opus (low) entregou 3 de 4 difíceis.")
    #expect(Retrospective.hardFact(Array(runs.prefix(2))) == nil)
    // Normal pieces and provider failures are not counted.
    #expect(Retrospective.hardFact((0..<3).map { run("n\($0)", ago: 60) }) == nil)
}

@Test func theAuditFactSaysHowOftenAuditsAskedForFixesAndWhatChanged() {
    let runs = [
        run("d1", label: "A", ago: 9_000),
        audit("a1", of: "A", verdict: "ship after fixes", ago: 8_900),
        run("r1", label: "A", ago: 8_800, redoOf: "d1"),
        run("d2", label: "B", ago: 7_000),
        audit("a2", of: "B", verdict: "ship", ago: 6_900),
        run("d3", label: "C", ago: 5_000),
        audit("a3", of: "C", verdict: "do not ship", ago: 4_900),
    ]
    #expect(Retrospective.auditFact(Trabalho.group(runs))
        == "Auditorias pediram correção em 67 % das entregas auditadas; 1 mudou o resultado.")
    #expect(Retrospective.auditFact(Trabalho.group(Array(runs.prefix(5)))) == nil)
    let approved = (0..<3).flatMap { [run("d\($0)", label: "L\($0)", ago: 9_000), audit("a\($0)", of: "L\($0)", verdict: "ship", ago: 8_000)] }
    #expect(Retrospective.auditFact(Trabalho.group(approved)) == "Auditorias aprovaram as 3 entregas auditadas sem pedir correção.")
}

@Test func theRedoFactSaysWhatRedoingCostAndItsShare() {
    let runs = [
        run("a", ago: 600, cost: 1.0),
        run("b", ago: 500, cost: 0.6),
        run("c", ago: 400, cost: 0.4, redoOf: "a"),
    ]
    #expect(Retrospective.redoFact(runs) == "Refazer custou $0.40 nos últimos 7 dias (20 % do total).")
    #expect(Retrospective.redoFact(Array(runs.prefix(2))) == nil)
    #expect(Retrospective.redoFact([run("a", ago: 1, cost: 1), run("b", ago: 1, cost: 1), run("c", ago: 1, cost: 1)]) == nil)
}

@Test func theFastestReviewerFactNeedsTwoWorkersWithThreeReviewsEach() {
    let fast = (0..<3).map { run("f\($0)", cli: .cursor, model: "grok", effort: nil, kind: .review, ago: 600, took: 70 + Double($0)) }
    let slow = (0..<3).map { run("s\($0)", model: "haiku", kind: .review, ago: 600, took: 150) }
    #expect(Retrospective.fastestReviewFact(fast + slow) == "grok é o mais rápido em revisão: mediana 1m 11s.")
    #expect(Retrospective.fastestReviewFact(fast) == nil)
    #expect(Retrospective.fastestReviewFact(fast + Array(slow.prefix(2))) == nil)
}

@Test func noFactIsSaidWithoutEnoughData() {
    #expect(Retrospective.facts(runs: [], trabalhos: []).isEmpty)
    let few = [run("a", ago: 60, cost: 1, difficulty: .hard)]
    #expect(Retrospective.facts(runs: few, trabalhos: Trabalho.group(few)).isEmpty)
}

// MARK: - Markdown

@Test func aTrabalhoIsCopiedAsMarkdownStepByStep() {
    let runs = [
        run("d1", label: "Cache", ago: 5_000, took: 300, cost: 0.4, score: 3, note: "Faltou invalidar.",
            pick: PickReason(code: .lineup, text: "1st in your lineup for hard pieces", position: 1)),
        audit("a1", of: "Cache", verdict: "ship after fixes", ago: 4_600, took: 72),
        run("r1", model: "sonnet", effort: "high", label: "Cache", state: .finished(exitCode: 1), ago: 4_000, took: 30,
            isError: true, answer: "error: build failed", redoOf: "d1"),
    ]
    let text = Retrospective.markdown(Trabalho.group(runs)[0], now: now)
    #expect(text == """
    ## Cache

    - Resultado: falhou
    - Tempo: 17m 10s · Custo: $0.40
    - Cadeia: opus (low) ✗ → auditoria grok ! → refeito sonnet (high) ✗

    ### Passos
    1. **opus (low)** ✗ — 5m 00s · $0.40 · 3/5
       - Escolha: 1st in your lineup for hard pieces
       - Nota do maestro: Faltou invalidar.
    2. **auditoria grok** ! — 1m 12s · $0.00
       - Veredito: ship after fixes
    3. **refeito sonnet (high)** ✗ — 30s · $0.00
       - Falha: error: build failed

    """)
}

@Test func withNothingSelectedTheDayIsCopied() {
    let runs = [
        run("d1", label: "Cache", ago: 3_600, took: 300, cost: 0.4, score: 5),
        run("old", label: "Ontem", ago: 2 * 86_400, cost: 1),
    ]
    let resumo = Resumo.make(runs: runs, project: CockpitProject(path: project), usage: nil, now: now, calendar: utc)
    let text = Retrospective.markdown(day: resumo)
    #expect(text.hasPrefix("# Retrospectiva de 11/11\n"))
    #expect(text.contains("Workers hoje: $0.40 · 0 tokens · 1 entrega"))
    #expect(text.contains("- **Cache** — entregue 5/5 · 5m 00s · $0.40\n  opus (low) ✓"))
    #expect(!text.contains("Ontem"))
    #expect(!text.contains("O que os números dizem"))
}

@MainActor
@Test func theResumoViewCopiesTheOpenTrabalhoOrTheDay() {
    let runs = [run("d1", label: "Cache", ago: 3_600, cost: 0.4, score: 5)]
    let resumo = Resumo.make(runs: runs, project: CockpitProject(path: project), usage: nil, now: now, calendar: utc)
    let view = ResumoView()
    view.show(resumo)
    #expect(view.markdown?.hasPrefix("# Retrospectiva") == true)
    view.expand("d1")
    #expect(view.markdown?.hasPrefix("## Cache") == true)
    // A trabalho no longer listed is closed on the next show.
    view.show(Resumo.make(runs: [], project: CockpitProject(path: project), usage: nil, now: now, calendar: utc))
    #expect(view.expanded == nil)
}

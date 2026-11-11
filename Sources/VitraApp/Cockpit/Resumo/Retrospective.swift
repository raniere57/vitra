import Foundation
import VitraOrchestrator

/// A piece of work as the user thinks of it: a delivery and everything that
/// hangs off it — its audits, its redos and its failover retries.
struct Trabalho: Equatable, Sendable {
    enum Role: Equatable, Sendable { case delivery, audit, redo, retry }

    struct Step: Equatable, Sendable {
        let run: Run
        let role: Role
    }

    enum Outcome: Equatable, Sendable {
        case running
        /// The last attempt delivered; `redos` attempts were redone before it.
        case delivered(score: Int?, redos: Int)
        case failed
        /// Stopped, or delivered and judged not what was asked with nothing after it.
        case discarded
    }

    /// The id of the run the trabalho started with.
    let id: String
    let title: String
    /// Oldest first.
    let steps: [Step]

    var started: Date { steps.first?.run.started ?? .distantPast }

    /// When the last step ended, or `now` while one is still going.
    func ended(now: Date) -> Date {
        if steps.contains(where: { $0.run.state == .running }) { return now }
        return steps.map { $0.run.ended ?? $0.run.started }.max() ?? started
    }

    func duration(now: Date) -> TimeInterval { ended(now: now).timeIntervalSince(started) }

    var cost: Double { steps.reduce(0) { $0 + ($1.run.output?.costUSD ?? 0) } }

    var outcome: Outcome {
        if steps.contains(where: { $0.run.state == .running }) { return .running }
        let attempts = steps.filter { $0.role != .audit }
        guard let last = (attempts.isEmpty ? steps : attempts).last?.run else { return .failed }
        switch last.state {
        case .running: return .running
        case .cancelled: return .discarded
        case .lost: return .failed
        case .finished:
            if Scoreboard.hasFailed(last) { return .failed }
            if last.rating?.isSatisfactory == false { return .discarded }
            return .delivered(score: last.rating?.score, redos: attempts.filter { $0.role == .redo }.count)
        }
    }

    var outcomeText: String {
        switch outcome {
        case .running: return "em andamento"
        case .failed: return "falhou"
        case .discarded: return "descartado"
        case let .delivered(score, redos):
            let done = redos == 0 ? "entregue" : "refeito \(redos)x e entregue"
            return done + (score.map { " \($0)/5" } ?? "")
        }
    }

    /// "opus (low) ✓ → auditoria grok ! → refeito sonnet (high) ✓".
    var chain: String { steps.map(\.chainText).joined(separator: " → ") }

    // MARK: - Grouping

    /// The runs grouped into trabalhos, newest first.
    ///
    /// A redo or a retry joins the trabalho of the run it redoes or retries; an
    /// audit joins that of the delivery its label names (see
    /// `StageModel.deliveryIDs`). One whose parent is not among `runs` — read
    /// too far back, or an audit of nothing known — starts a trabalho of its own.
    static func group(_ runs: [Run]) -> [Trabalho] {
        let byID = Dictionary(runs.map { ($0.id, $0) }) { first, _ in first }
        let auditOf = StageModel.deliveryIDs(forAuditsIn: runs)
        var roots: [String: String] = [:]
        func root(_ id: String, depth: Int) -> String {
            if let known = roots[id] { return known }
            guard let run = byID[id] else { return id }
            let parent = StageModel.isAudit(run) ? auditOf[id] : (run.redoOf ?? run.retryOf)
            // The depth guards against a cycle in hand-edited records.
            let found = parent.flatMap { byID[$0] != nil && depth < 64 ? root($0, depth: depth + 1) : nil } ?? id
            roots[id] = found
            return found
        }
        let grouped = Dictionary(grouping: runs) { root($0.id, depth: 0) }
        return grouped.map { id, members in
            let steps = members.sorted { ($0.started, $0.id) < ($1.started, $1.id) }.map { Step(run: $0, role: role(of: $0)) }
            return Trabalho(id: id, title: title(of: byID[id] ?? steps[0].run), steps: steps)
        }
        .sorted { ($0.started, $0.id) > ($1.started, $1.id) }
    }

    static func role(of run: Run) -> Role {
        if StageModel.isAudit(run) { return .audit }
        if run.redoOf != nil { return .redo }
        if run.retryOf != nil { return .retry }
        return .delivery
    }

    private static func title(of run: Run) -> String {
        let label = run.spec.label.flatMap { $0.isEmpty ? nil : WorkerBoard.firstLine($0) }
        return label ?? WorkerBoard.firstLine(run.spec.prompt)
    }
}

/// What an auditor said, from the first line of its answer.
enum AuditVerdict: Equatable, Sendable {
    case ship, fixes, block

    init?(_ run: Run) {
        guard Resumo.isDelivery(run) else { return nil }
        switch StageModel.auditVerdict(run.output?.text) {
        case "ok": self = .ship
        case "corrigir": self = .fixes
        case "não": self = .block
        default: return nil
        }
    }

    var asksForChanges: Bool { self != .ship }
}

extension Trabalho.Step {
    var name: String { WorkerBoard.shortName(run.spec.model, effort: run.spec.effort) }

    var roleWord: String? {
        switch role {
        case .delivery: return nil
        case .audit: return "auditoria"
        case .redo: return "refeito"
        case .retry: return "failover"
        }
    }

    /// ✓ delivered and not judged short, ✗ failed or judged short, ! an audit
    /// that asked for fixes, … still going, – stopped.
    var mark: String {
        if role == .audit, let verdict = AuditVerdict(run) {
            switch verdict {
            case .ship: return "✓"
            case .fixes: return "!"
            case .block: return "✗"
            }
        }
        switch run.state {
        case .running: return "…"
        case .cancelled: return "–"
        case .lost: return "✗"
        case .finished:
            return Scoreboard.hasFailed(run) || run.rating?.isSatisfactory == false ? "✗" : "✓"
        }
    }

    var chainText: String { ([roleWord, name].compactMap { $0 } + [mark]).joined(separator: " ") }

    /// What went wrong, in a line, when it did.
    var failure: String? {
        if let provider = run.providerFailure { return "provedor: \(provider.reason)" }
        if run.state == .lost { return "perdido: o processo sumiu sem código de saída" }
        if let minutes = run.timedOutAfter { return "estourou o prazo de \(minutes) min" }
        guard Scoreboard.hasFailed(run) else { return nil }
        let said = WorkerBoard.firstLine(run.output?.text ?? run.errorTail ?? "")
        return said.isEmpty ? "sem resposta" : said
    }

    /// An auditor's verdict line, as it wrote it.
    var verdictLine: String? {
        guard role == .audit, AuditVerdict(run) != nil, let text = run.output?.text else { return nil }
        return WorkerBoard.firstLine(text)
    }
}

/// The facts header and the Markdown of the Retrospectiva. Pure.
enum Retrospective {
    /// Fewer samples than this and a fact is not said.
    static let enoughSamples = 3
    static let mostFacts = 4

    /// Up to four plain facts about `runs` and `trabalhos`, the last seven
    /// days of one project: only those with enough data behind them.
    static func facts(runs: [Run], trabalhos: [Trabalho]) -> [String] {
        Array([hardFact(runs), auditFact(trabalhos), redoFact(runs), fastestReviewFact(runs)].compactMap { $0 }.prefix(mostFacts))
    }

    private static func name(_ run: Run) -> String { WorkerBoard.shortName(run.spec.model, effort: run.spec.effort) }

    /// Runs that are a verdict on their worker: ended, and not the provider's doing.
    private static func judged(_ runs: [Run]) -> [Run] {
        runs.filter { run in
            guard run.providerFailure == nil else { return false }
            switch run.state {
            case .finished, .lost: return true
            case .running, .cancelled: return false
            }
        }
    }

    /// "opus (low) entregou 8 de 9 difíceis; sonnet (high), 4 de 7."
    static func hardFact(_ runs: [Run]) -> String? {
        let hard = judged(runs).filter { $0.spec.difficulty == .hard && !StageModel.isAudit($0) }
        let byWorker = Dictionary(grouping: hard, by: name)
            .filter { $0.value.count >= enoughSamples }
            .map { worker, runs in
                (worker, runs.count, runs.filter { Resumo.isDelivery($0) && $0.rating?.isSatisfactory != false }.count)
            }
            .sorted { ($1.1, $0.0) < ($0.1, $1.0) }
        guard let first = byWorker.first else { return nil }
        var line = "\(first.0) entregou \(first.2) de \(first.1) difíceis"
        if byWorker.count > 1 { line += "; \(byWorker[1].0), \(byWorker[1].2) de \(byWorker[1].1)" }
        return line + "."
    }

    /// "Auditorias pediram correção em 35 % das entregas auditadas; 2 mudaram o resultado."
    static func auditFact(_ trabalhos: [Trabalho]) -> String? {
        var verdicts = 0
        var asked = 0
        var changed = 0
        for trabalho in trabalhos {
            for audit in trabalho.steps where audit.role == .audit {
                guard let verdict = AuditVerdict(audit.run) else { continue }
                verdicts += 1
                guard verdict.asksForChanges else { continue }
                asked += 1
                if trabalho.steps.contains(where: { $0.role == .redo && $0.run.started > audit.run.started }) { changed += 1 }
            }
        }
        guard verdicts >= enoughSamples else { return nil }
        guard asked > 0 else { return "Auditorias aprovaram as \(verdicts) entregas auditadas sem pedir correção." }
        let changes = switch changed {
        case 0: "nenhuma mudou o resultado"
        case 1: "1 mudou o resultado"
        default: "\(changed) mudaram o resultado"
        }
        return "Auditorias pediram correção em \(percent(asked, of: verdicts)) das entregas auditadas; \(changes)."
    }

    /// "Refazer custou $1.84 nos últimos 7 dias (18 % do total)."
    static func redoFact(_ runs: [Run]) -> String? {
        let paid = runs.filter { ($0.output?.costUSD ?? 0) > 0 }
        let total = paid.reduce(0) { $0 + ($1.output?.costUSD ?? 0) }
        let redo = paid.filter { $0.redoOf != nil }.reduce(0) { $0 + ($1.output?.costUSD ?? 0) }
        guard paid.count >= enoughSamples, redo > 0, total > 0 else { return nil }
        return "Refazer custou \(WorkerBoard.money(redo)) nos últimos 7 dias (\(Int((redo / total * 100).rounded())) % do total)."
    }

    /// "cursor-grok-4.6-low-fast é o mais rápido em revisão: mediana 1m 12s."
    /// Only said when two workers or more have enough reviews to compare.
    static func fastestReviewFact(_ runs: [Run]) -> String? {
        let reviews = judged(runs).filter { $0.spec.kind == .review && Resumo.isDelivery($0) }
        let medians = Dictionary(grouping: reviews, by: name)
            .filter { $0.value.count >= enoughSamples }
            .compactMap { worker, runs in Scoreboard.median(runs.map(\.duration)).map { (worker, $0) } }
        guard medians.count >= 2, let fastest = medians.min(by: { ($0.1, $0.0) < ($1.1, $1.0) }) else { return nil }
        return "\(fastest.0) é o mais rápido em revisão: mediana \(WorkerBoard.duration(fastest.1))."
    }

    private static func percent(_ part: Int, of whole: Int) -> String {
        "\(Int((Double(part) / Double(whole) * 100).rounded())) %"
    }

    // MARK: - Markdown

    /// One trabalho, step by step.
    static func markdown(_ trabalho: Trabalho, now: Date) -> String {
        var lines = [
            "## \(trabalho.title)",
            "",
            "- Resultado: \(trabalho.outcomeText)",
            "- Tempo: \(WorkerBoard.duration(trabalho.duration(now: now))) · Custo: \(WorkerBoard.money(trabalho.cost))",
            "- Cadeia: \(trabalho.chain)",
            "",
            "### Passos",
        ]
        for (index, step) in trabalho.steps.enumerated() {
            let head = ([step.roleWord, step.name].compactMap { $0 }).joined(separator: " ")
            let figures = [
                WorkerBoard.duration((step.run.ended ?? now).timeIntervalSince(step.run.started)),
                WorkerBoard.money(step.run.output?.costUSD ?? 0),
                step.run.rating.map { "\($0.score)/5" },
            ].compactMap { $0 }.joined(separator: " · ")
            lines.append("\(index + 1). **\(head)** \(step.mark) — \(figures)")
            if let pick = step.run.pick { lines.append("   - Escolha: \(pick.text)") }
            if let note = step.run.rating?.note, !note.isEmpty { lines.append("   - Nota do maestro: \(note)") }
            if let verdict = step.verdictLine { lines.append("   - Veredito: \(verdict)") }
            if let failure = step.failure { lines.append("   - Falha: \(failure)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The day: what it cost, each trabalho of the day in a line, and the facts.
    static func markdown(day resumo: Resumo) -> String {
        let start = resumo.calendar.startOfDay(for: resumo.now)
        let parts = resumo.calendar.dateComponents([.day, .month], from: resumo.now)
        let today = resumo.today
        var lines = [
            String(format: "# Retrospectiva de %02d/%02d", parts.day ?? 0, parts.month ?? 0),
            "",
            "Workers hoje: \(WorkerBoard.money(today.cost)) · \(WorkerBoard.tokens(today.tokens)) · \(Resumo.countsText(today))",
            "",
            "## Trabalhos",
        ]
        let ofDay = resumo.trabalhos.filter { $0.steps.contains { $0.run.started >= start } }
        if ofDay.isEmpty { lines.append("Nenhum trabalho hoje.") }
        for trabalho in ofDay {
            lines.append("- **\(trabalho.title)** — \(trabalho.outcomeText) · "
                + "\(WorkerBoard.duration(trabalho.duration(now: resumo.now))) · \(WorkerBoard.money(trabalho.cost))")
            lines.append("  \(trabalho.chain)")
        }
        if !resumo.facts.isEmpty {
            lines += ["", "## O que os números dizem"] + resumo.facts.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

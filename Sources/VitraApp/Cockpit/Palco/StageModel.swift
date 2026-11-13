import Foundation
import VitraOrchestrator

/// Which colour a worker is drawn in: one per CLI.
enum StageProvider: CaseIterable {
    case claude, opencode, cursor, gemini

    init(_ cli: WorkerCLI) {
        switch cli {
        case .claude: self = .claude
        case .opencode: self = .opencode
        case .cursor: self = .cursor
        case .gemini: self = .gemini
        }
    }
}

/// One worker as the Palco draws it: everything the stage and the timeline
/// need, worked out from a `Run` so that neither has to read one.
struct StageNode: Equatable {
    enum Outcome: Equatable {
        case running
        case done
        case failed
        /// Stopped on purpose: neither a result nor a failure.
        case stopped
    }

    let id: String
    let provider: StageProvider
    let glyph: String
    let label: String
    let outcome: Outcome
    let isAudit: Bool
    /// The delivery this audit reads, when that delivery is on the stage too.
    let auditOf: String?
    let started: Date
    let ended: Date?
    /// 1...5, once the maestro has rated the delivery.
    let score: Int?
    /// How much of the run's time allowance is used, 0...1.
    let deadlineFraction: Double
    let stateText: String
    /// Quiet for longer than `StageModel.silentAfter`: drawn dimmer.
    let isSilent: Bool
    /// 1 for a fresh node, less for one about to leave.
    let emphasis: Double
    let model: String
    let effort: String?
    let kind: TaskKind?
    let canEdit: Bool
    let costUSD: Double?
    let tokens: Int?
    let branch: String?
}

/// Which runs the Palco shows, and what each one looks like. Pure: the views
/// only draw what comes out of here.
enum StageModel {
    /// How long a finished worker stays on the stage.
    static let finishedLinger: TimeInterval = 15 * 60
    /// Where a finished worker starts to fade, inside that time.
    static let fadeFrom: TimeInterval = 10 * 60
    static let maxNodes = 12
    /// A running worker that has written nothing for this long is dimmed.
    static let silentAfter: TimeInterval = 120
    static let auditPrefix = "auditoria: "
    // ponytail: the run record has a deadline the feed does not surface, so the
    // ring reads the spec's minutes, else these defaults; read the record's own if that is ever exposed.
    static let defaultMinutes = 45
    static let auditMinutes = 8

    static func isAudit(_ run: Run) -> Bool {
        run.spec.kind == .review && (run.spec.label?.hasPrefix(auditPrefix) ?? false)
    }

    /// The runs to draw as nodes, oldest start first.
    static func nodes(from runs: [Run], now: Date) -> [StageNode] {
        let shown = Array(
            runs.filter { isShown($0, now: now) }
                .sorted(by: moreRelevant)
                .prefix(maxNodes)
        ).sorted { ($0.started, $0.id) < ($1.started, $1.id) }
        let delivery = deliveryIDs(forAuditsIn: shown)
        return shown.map { node($0, auditOf: delivery[$0.id], now: now) }
    }

    /// When the stage next changes by itself — a finished worker leaving — or nil.
    static func nextExpiry(_ nodes: [StageNode]) -> Date? {
        nodes.compactMap { $0.outcome == .running ? nil : ($0.ended ?? $0.started).addingTimeInterval(finishedLinger) }.min()
    }

    /// Audit run id → the id of the delivery it audits, for the audits whose
    /// delivery is among `runs`. An audit is labelled "auditoria: <label of the
    /// delivery>" (or with its id when the delivery had no label); where several
    /// deliveries share a label, the latest one that started before the audit.
    static func deliveryIDs(forAuditsIn runs: [Run]) -> [String: String] {
        var result: [String: String] = [:]
        for audit in runs where isAudit(audit) {
            let target = String(audit.spec.label?.dropFirst(auditPrefix.count) ?? "")
            let match = runs
                .filter { !isAudit($0) && $0.id != audit.id && ($0.spec.label == target || $0.id == target) && $0.started <= audit.started }
                .max { $0.started < $1.started }
            if let match { result[audit.id] = match.id }
        }
        return result
    }

    static func deadlineFraction(started: Date, ended: Date?, now: Date, minutes: Int) -> Double {
        let allowance = TimeInterval(max(minutes, 1)) * 60
        return min(max((ended ?? now).timeIntervalSince(started) / allowance, 0), 1)
    }

    // MARK: Words

    /// A two or three letter mark for the model's family: "Op", "So", "Ds".
    static func glyph(model: String) -> String {
        let name = (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
        let families: [(String, String)] = [
            ("opus", "Op"), ("sonnet", "So"), ("haiku", "Ha"), ("gemini", "Gem"), ("deepseek", "Ds"),
            ("glm", "Glm"), ("composer", "Cmp"), ("gpt", "Gpt"), ("codex", "Cdx"), ("kimi", "Ki"),
            ("qwen", "Qw"), ("grok", "Gk"), ("llama", "Ll"), ("mistral", "Mi"), ("claude", "Cl"),
        ]
        if let family = families.first(where: { name.contains($0.0) }) { return family.1 }
        let letters = name.filter(\.isLetter).prefix(2)
        return letters.isEmpty ? "?" : letters.prefix(1).uppercased() + letters.dropFirst()
    }

    /// The model as the core wears it: no "Claude " in front, no "(1M context)" behind.
    static func coreTitle(_ model: String?) -> String {
        guard var name = model?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "claude" }
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]).trimmingCharacters(in: .whitespaces) }
        if name.lowercased().hasPrefix("claude ") { name = String(name.dropFirst(7)) }
        return name.isEmpty ? "claude" : name
    }

    /// The percent in a label such as "semana 62%", or nil.
    static func percent(inUsageText text: String) -> Double? {
        Double(text.filter(\.isNumber)).map { min(max($0, 0), 100) }
    }

    /// The label under a node: the run's own words, without the audit prefix.
    static func label(_ run: Run) -> String {
        let text = run.spec.label.flatMap { $0.isEmpty ? nil : $0 } ?? run.spec.prompt
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.hasPrefix(auditPrefix) ? "audit · " + line.dropFirst(auditPrefix.count) : line
    }

    // MARK: Derivation

    private static func isShown(_ run: Run, now: Date) -> Bool {
        run.state == .running || now.timeIntervalSince(run.ended ?? run.started) < finishedLinger
    }

    /// Running first, then the most recently active.
    private static func moreRelevant(_ a: Run, _ b: Run) -> Bool {
        if (a.state == .running) != (b.state == .running) { return a.state == .running }
        let (ta, tb) = (a.ended ?? a.started, b.ended ?? b.started)
        return ta != tb ? ta > tb : a.id < b.id
    }

    /// Mirrors how the workers list sorts a run into done / failed / stopped.
    private static func outcome(_ run: Run) -> StageNode.Outcome {
        switch run.state {
        case .running: return .running
        case .cancelled: return .stopped
        case .lost: return .failed
        case .finished:
            return run.output?.isError == true || run.rating?.isSatisfactory == false ? .failed : .done
        }
    }

    private static func node(_ run: Run, auditOf: String?, now: Date) -> StageNode {
        let outcome = outcome(run)
        let audit = isAudit(run)
        let minutes = run.spec.minutes ?? (audit ? auditMinutes : defaultMinutes)
        let age = outcome == .running ? 0 : now.timeIntervalSince(run.ended ?? run.started)
        let fade = min(max((age - fadeFrom) / (finishedLinger - fadeFrom), 0), 1)
        let tokens = run.output.map { $0.inputTokens + $0.outputTokens }
        return StageNode(
            id: run.id,
            provider: StageProvider(run.spec.cli),
            glyph: glyph(model: run.spec.model),
            label: label(run),
            outcome: outcome,
            isAudit: audit,
            auditOf: auditOf,
            started: run.started,
            ended: run.ended,
            score: run.rating?.score,
            deadlineFraction: deadlineFraction(started: run.started, ended: run.ended, now: now, minutes: minutes),
            stateText: stateText(run, outcome, now: now),
            isSilent: outcome == .running && (run.silentFor ?? 0) > silentAfter,
            emphasis: 1 - 0.5 * fade,
            model: run.spec.model,
            effort: run.spec.effort,
            kind: run.spec.kind,
            canEdit: run.spec.access == .edit,
            costUSD: (run.output?.costUSD).flatMap { $0 > 0 ? $0 : nil },
            tokens: tokens.flatMap { $0 > 0 ? $0 : nil },
            branch: run.branch
        )
    }

    static func stateText(_ run: Run, _ outcome: StageNode.Outcome, now: Date) -> String {
        // An audit's line is too short for its rating; the card carries it.
        let score = isAudit(run) ? "" : run.rating.map { " \($0.score)/5" } ?? ""
        // An audit is a short disc beside its delivery: its verdict, when its
        // answer's first line gives one, says more than "pronto".
        if isAudit(run), outcome == .done, let verdict = auditVerdict(run.output?.text) { return verdict }
        switch outcome {
        case .running: return clock(now.timeIntervalSince(run.started))
        case .done: return "pronto" + score
        case .failed: return (run.state == .lost ? "perdido" : "falhou") + score
        case .stopped: return "cancelado"
        }
    }

    /// "ok", "corrigir" or "não" for an audit whose answer opens with ship,
    /// ship after fixes, or do not ship; nil when the first line says none.
    static func auditVerdict(_ answer: String?) -> String? {
        guard let first = answer?.split(whereSeparator: \.isNewline).first?.lowercased() else { return nil }
        if first.contains("do not ship") || first.contains("don't ship") || first.contains("not ship") { return "não" }
        if first.contains("after fixes") || first.contains("with fixes") { return "corrigir" }
        if first.contains("ship") { return "ok" }
        return nil
    }

    /// "2:14", or "1:02:09" past the hour: narrow enough for under a node.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

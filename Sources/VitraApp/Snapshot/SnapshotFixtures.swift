import AppKit
import Foundation
import VitraOrchestrator

/// Made-up data for `Vitra snapshot`, built in code with the same types the
/// app feeds its views with. Nothing here reads ~/.vitra or the user's files:
/// the project is a folder this writes into a temporary directory.
struct SnapshotFixtures {
    let now: Date
    /// The fixture project's folder, named "vitra".
    let project: URL

    var path: String { project.path }

    // MARK: - Workers

    /// The workers panel's rows, newest first: running, finished and rated 5,
    /// finished and unrated, failed, cancelled, and an audit.
    func workerRuns() -> [Run] {
        [
            run("a1b2c3d4", "opencode/deepseek-v4.1-flash-free", .opencode, label: "Migrar a lista de arquivos para células reutilizáveis",
                kind: .implement, access: .edit, state: .running, ago: 134),
            run("b2c3d4e5", "claude-haiku-5-5", .claude, effort: "low", label: "Mapear o fluxo do ranking de workers",
                kind: .explore, ago: 900, took: 41, cost: 0.0123, tokens: (18_400, 2_100), score: 5, note: "Exato, com arquivo e linha.",
                answer: "O ranking nasce em Scoreboard.scores(runs), que agrupa por tipo, CLI, modelo e effort.\nWorkerBoard.ranking formata cada ModelScore em uma RankingRow."),
            run("c3d4e5f6", "gemini-3-flash", .gemini, label: "Escrever testes do WorkerBoard.startedText",
                kind: .test, access: .edit, ago: 2_400, took: 96, cost: 0.0041, tokens: (9_800, 1_450),
                answer: "Adicionei 6 testes: mesmo dia, outro dia, outro ano e virada de meia-noite."),
            run("d4e5f607", "claude-sonnet-5-5", .claude, effort: "medium", label: "Corrigir o build do CGhosttyVT no worktree",
                kind: .implement, access: .edit, state: .finished(exitCode: 1), ago: 4_100, took: 58, cost: 0.0310, tokens: (31_000, 900),
                isError: true, answer: "error: 'ghostty/vt.h' file not found\nvendor/ e Sources/CGhosttyVT/include/ghostty são ignorados pelo git."),
            run("e5f60718", "opencode/glm-5-free", .opencode, label: "Revisar o diff do GitPanel",
                kind: .review, state: .cancelled, ago: 6_000, took: 12),
            run("f6071829", "claude-sonnet-5-5", .claude, effort: "high", label: "Auditar: cache do ranking",
                kind: .review, ago: 7_800, took: 73, cost: 0.0520, tokens: (42_000, 2_800), score: 4, note: "Aprovado, com uma ressalva sobre invalidação.",
                answer: "Sem regressões. Ressalva: o cache não é invalidado quando uma nota é corrigida."),
        ]
    }

    /// The Ranking tab's sources: a dozen workers across kinds, difficulties
    /// and providers — haiku at three efforts, the Groks at two — over the
    /// Escalação's record, one run its provider refused, and a catalogue that
    /// offers a few workers never used.
    func rankingData() -> RankingData {
        let lineupData = lineupData()
        let table: [(WorkerCLI, String, String?, TaskKind, Difficulty, [Int?], Int, Double, Double)] = [
            (.opencode, "opencode/deepseek-v4.1-flash-free", nil, .explore, .easy, [4, 5, 4, 4, 5, 4], 0, 38, 0),
            (.claude, "haiku", "low", .explore, .normal, [5, 5, 4, 5, 5], 0, 44, 0.012),
            (.claude, "haiku", "high", .explore, .normal, [4, 5], 0, 70, 0.031),
            (.claude, "sonnet", "high", .implement, .hard, [5, 4, 5, 5, 4], 0, 210, 0.19),
            (.opencode, "opencode/deepseek-v4.1-flash-free", nil, .implement, .normal, [3, 4, 2, 4, nil, nil], 1, 260, 0),
            (.cursor, "grok-4.7-high-fast", nil, .implement, .hard, [nil, nil, nil], 0, 180, 0.08),
            (.cursor, "grok-4.7-low-fast", nil, .review, .normal, [4, 4, 5], 0, 62, 0.021),
            (.claude, "sonnet", "high", .review, .hard, [5, 4, 5, 5], 0, 95, 0.07),
            (.opencode, "opencode/glm-5.3-flash-free", nil, .review, .easy, [3, 4, 3], 0, 120, 0),
            (.claude, "haiku", "medium", .test, .normal, [4, 4, 5, 4], 0, 150, 0.03),
            (.gemini, "gemini-3.8-flash-low", nil, .docs, .easy, [4, 5], 0, 30, 0),
        ]
        var runs: [Run] = []
        for (cli, model, effort, kind, difficulty, scores, failures, seconds, cost) in table {
            for (index, score) in scores.enumerated() {
                let failed = index < failures
                runs.append(run(
                    "r\(runs.count)", model, cli, effort: effort, label: nil, kind: kind,
                    state: .finished(exitCode: failed ? 1 : 0), ago: Double(index + 1) * 3_600, took: seconds + Double(index) * 3,
                    cost: cost, tokens: (12_000, 1_500), score: failed ? nil : score, isError: failed, difficulty: difficulty
                ))
            }
        }
        // Refused by its provider: no use of gemini pro, which stays "nunca usado".
        runs.append(run("rq", "gemini-3.8-pro-high", .gemini, label: nil, kind: .implement, state: .finished(exitCode: 1),
                        ago: 600, took: 3, isError: true, providerFailure: .quota("sem cota")))
        let history = runs + lineupData.history
        let listing = ModelCatalog.Listing(
            claude: true, openCode: ["opencode/glm-5.3-flash-free", "opencode/deepseek-v4.1-flash-free"],
            gemini: ["gemini-3.8-flash-low\tGemini Flash", "gemini-3.8-flash-high\tGemini Flash", "gemini-3.8-pro-high\tGemini Pro"],
            cursor: ["cursor-grok-4.6-low-fast", "grok-4.7-low-fast", "grok-4.7-high-fast", "grok-4.7-xhigh-fast"]
        )
        return RankingData(
            lineup: lineupData.lineup, history: history, offers: ModelCatalog.offers(listing),
            demoted: LineupBoard.demoted(lineupData.lineup, history: history)
        )
    }

    /// The default lineup with a record on it: opus rated poorly on hard
    /// implementation, so it shows demoted; the user added sonnet to easy.
    func lineupData() -> LineupData {
        let table: [(WorkerCLI, String, String?, Difficulty, [Int], Double)] = [
            (.claude, "opus", "low", .hard, [3, 3], 240),
            (.claude, "sonnet", "high", .hard, [5, 4, 5], 310),
            (.cursor, "cursor-grok-4.6-low-fast", nil, .normal, [4, 5, 5, 4], 48),
            (.claude, "haiku", "low", .normal, [4], 95),
            (.opencode, "opencode/glm-5.3-flash-free", nil, .easy, [4, 5], 31),
        ]
        var history: [Run] = []
        for (cli, model, effort, difficulty, scores, seconds) in table {
            for (index, score) in scores.enumerated() {
                history.append(run(
                    "l\(history.count)", model, cli, effort: effort, label: nil, kind: .implement,
                    ago: Double(index + 1) * 3_600, took: seconds + Double(index) * 4, score: score, difficulty: difficulty
                ))
            }
        }
        let sonnet = ModelCatalog.Offer(cli: .claude, model: "sonnet", effort: "high")
        let listing = ModelCatalog.Listing(
            claude: true, openCode: ["opencode/glm-5.3-flash-free", "opencode/deepseek-v4.1-flash-free"],
            gemini: nil, cursor: ["cursor-grok-4.6-low-fast", "grok-4.7-low-fast", "grok-4.7-high-fast"]
        )
        return LineupData(
            lineup: Lineup.standard.with(.easy, Lineup.standard.easy + [sonnet]),
            history: history,
            offers: ModelCatalog.offers(listing)
        )
    }

    func run(
        _ id: String, _ model: String, _ cli: WorkerCLI, effort: String? = nil, label: String?, kind: TaskKind,
        access: WorkerAccess = .read, state: Run.State = .finished(exitCode: 0), ago: TimeInterval, took: TimeInterval = 0,
        cost: Double = 0, tokens: (Int, Int) = (0, 0), score: Int? = nil, note: String? = nil, isError: Bool = false,
        answer: String? = nil, branch: String? = nil, silent: TimeInterval? = nil, difficulty: Difficulty? = nil,
        project: String? = nil, pick: PickReason? = nil, providerFailure: ProviderFailure? = nil,
        redoOf: String? = nil, retryOf: String? = nil
    ) -> Run {
        let started = now.addingTimeInterval(-ago)
        let isRunning = state == .running
        let hasOutput: Bool
        if case .finished = state { hasOutput = true } else { hasOutput = false }
        return Run(
            id: id,
            spec: WorkerSpec(
                cli: cli, model: model, prompt: label ?? "tarefa", directory: path, access: access,
                label: label, kind: kind, effort: effort, project: project ?? path, difficulty: difficulty
            ),
            state: state,
            pid: isRunning ? 4242 : nil,
            started: started,
            ended: isRunning ? nil : started.addingTimeInterval(took),
            output: hasOutput
                ? WorkerOutput(text: answer ?? "ok", isError: isError, costUSD: cost, inputTokens: tokens.0, outputTokens: tokens.1)
                : nil,
            errorTail: nil,
            branch: branch,
            rating: score.map { Rating(score: $0, note: note, rated: started.addingTimeInterval(took + 30)) },
            silentFor: isRunning ? silent : nil,
            providerFailure: providerFailure,
            wasPicked: pick != nil,
            pick: pick,
            retryOf: retryOf,
            redoOf: redoOf
        )
    }

    // MARK: - The Palco

    /// A busy stage: workers of every provider running, some finished and rated,
    /// one failed, one stopped, and two audits — one reading a delivery, one
    /// with its verdict in.
    func palcoRuns() -> [Run] {
        let m = 60.0
        return [
            run("p01", "opencode/deepseek-v4.1-flash-free", .opencode, label: "Migrar a lista de arquivos para células reutilizáveis",
                kind: .implement, access: .edit, state: .running, ago: 6.2 * m, branch: "vitra/p01"),
            run("p02", "claude-sonnet-5-5", .claude, effort: "medium", label: "Corrigir o build do CGhosttyVT no worktree",
                kind: .implement, access: .edit, state: .running, ago: 2.6 * m, branch: "vitra/p02"),
            run("p03", "gemini-3-flash", .gemini, label: "Escrever testes do WorkerBoard",
                kind: .test, access: .edit, state: .running, ago: 11.4 * m, branch: "vitra/p03", silent: 200),
            run("p04", "claude-haiku-5-5", .claude, effort: "low", label: "Mapear o fluxo do ranking",
                kind: .explore, ago: 9.5 * m, took: 41, cost: 0.0123, tokens: (18_400, 2_100), score: 5),
            run("p05", "composer-2", .cursor, label: "Revisar o diff do GitPanel",
                kind: .implement, access: .edit, ago: 8 * m, took: 150, cost: 0.04, tokens: (22_000, 3_100), branch: "vitra/p05"),
            run("p06", "claude-opus-5-5", .claude, effort: "high", label: "auditoria: Revisar o diff do GitPanel",
                kind: .review, state: .running, ago: 1.4 * m),
            run("p07", "claude-sonnet-5-5", .claude, effort: "medium", label: "Atualizar o tema para papéis",
                kind: .implement, access: .edit, state: .finished(exitCode: 1), ago: 13 * m, took: 190, cost: 0.031, tokens: (31_000, 900),
                isError: true, answer: "error: tema sem papel `muted`"),
            run("p08", "opencode/glm-5-free", .opencode, label: "Rascunho do guia de cores",
                kind: .docs, state: .cancelled, ago: 16 * m, took: 70),
            run("p09", "claude-sonnet-5-5", .claude, effort: "medium", label: "Ajustar o cabeçalho do maestro",
                kind: .implement, access: .edit, ago: 17 * m, took: 210, cost: 0.06, tokens: (40_000, 4_000), score: 4, branch: "vitra/p09"),
            run("p10", "claude-opus-5-5", .claude, effort: "high", label: "auditoria: Ajustar o cabeçalho do maestro",
                kind: .review, ago: 12.5 * m, took: 95, cost: 0.08, tokens: (30_000, 2_000), score: 5),
        ]
    }

    /// Nothing in the field: the one worker there was finished long ago.
    func palcoQuiet() -> [Run] {
        [run("q01", "claude-sonnet-5-5", .claude, label: "Revisar o ranking", kind: .review, ago: 41 * 60, took: 120, score: 4)]
    }

    /// Twelve workers at once, the most the stage shows.
    func palcoCrowd() -> [Run] {
        let m = 60.0
        let providers: [(String, WorkerCLI)] = [
            ("claude-sonnet-5-5", .claude), ("opencode/deepseek-v4.1-flash-free", .opencode), ("gemini-3-flash", .gemini), ("composer-2", .cursor),
            ("claude-haiku-5-5", .claude), ("opencode/glm-5-free", .opencode),
        ]
        let labels = [
            "Migrar a lista de arquivos", "Mapear o fluxo do ranking", "Escrever testes do WorkerBoard", "Revisar o diff do GitPanel",
            "Corrigir o build do CGhosttyVT", "Rascunho do guia de cores", "Atualizar o tema para papéis", "Ajustar o cabeçalho do maestro",
            "Cobrir o RunFeed com testes", "Explorar o fluxo de merge", "Documentar o ranking", "Revisar a barra de abas",
        ]
        return labels.enumerated().map { index, label in
            let (model, cli) = providers[index % providers.count]
            let running = index % 3 == 0
            return run(
                "c\(index)", model, cli, label: label, kind: index % 2 == 0 ? .implement : .explore, access: index % 2 == 0 ? .edit : .read,
                state: running ? .running : (index % 5 == 4 ? .finished(exitCode: 1) : .finished(exitCode: 0)),
                ago: (Double(index) * 1.1 + 2) * m, took: 120, cost: 0.02, tokens: (9_000, 1_000),
                score: running || index % 5 == 4 ? nil : (index % 4 == 1 ? 5 : 4), isError: index % 5 == 4
            )
        }
    }

    // MARK: - Git

    func gitEvents() -> [GitEvent] {
        let pull = "https://github.com/raniere/vitra/pull"
        let rows: [(GitEvent.Kind, String, String, TimeInterval, String?)] = [
            (.commit, "fix(agents): proven workers do the work, learning is every fifth piece", "511c9ec · Raniere", 420, nil),
            (.push, "push → origin/main", "511c9ec · fix(agents): proven workers do the work", 480, nil),
            (.pullRequest, "Vitra escolhe o operário", "#42 · merged · vitra/28309066", 3_200, "\(pull)/42"),
            (.commit, "perf(agents): small changes stay with the maestro and skip the audit", "38835ee · Raniere", 5_400, nil),
            (.commit, "vitra 28309066: Vitra escolhe o operário", "e57fd9e · Vitra", 9_000, nil),
            (.push, "push → origin/vitra/28309066", "e57fd9e · vitra 28309066", 9_100, nil),
            (.commit, "feat(agents): spread audits over the cheap auditors and list untried workers", "dda3a7f · Raniere", 86_400, nil),
            (.pullRequest, "Ranking por tipo de tarefa", "#41 · open · vitra/ranking", 90_000, "\(pull)/41"),
            (.commit, "docs: how the maestro picks a worker", "9f3a1b0 · Raniere", 200_000, nil),
            (.commit, "chore: bump vendored ghostty-vt", "0c4d2e8 · Raniere", 400_000, nil),
        ]
        return rows.map { GitEvent(kind: $0.0, title: $0.1, detail: $0.2, date: now.addingTimeInterval(-$0.3), url: $0.4) }
    }

    // MARK: - The maestro

    var maestro: MaestroModel {
        MaestroModel(name: "Opus 5.5", effort: "high", session: "vitra · snapshots da interface")
    }

    /// Past the tab bar's 80% mark, so its chip shows.
    var subscription: SubscriptionUsage {
        SubscriptionUsage(sevenDay: 87, fiveHour: 18, updated: now)
    }

    var usage: UsageLabel? {
        MaestroStatus.label(subscription, now: now)
    }

    /// The workers' runs plus an opencode run that hit its limit 12 minutes
    /// ago, in 4 seconds: what the tab bar's provider chips are derived from.
    func chipRuns() -> [Run] {
        workerRuns() + [
            run("0f1e2d3c", "opencode/deepseek-v4.1-flash-free", .opencode, label: "Resumir o diff do GitPanel",
                kind: .review, state: .finished(exitCode: 1), ago: 12 * 60, took: 4, isError: true,
                answer: "Error: usage limit reached for the free tier"),
        ]
    }

    // MARK: - Waiting for you

    /// The selected project's maestro asks for a permission; the second tab's
    /// has been waiting for the next instruction.
    func attention() -> [String: AttentionRecord] {
        [
            path: AttentionRecord(state: .needsPermission, message: "Claude precisa de permissão para usar Bash", since: now.addingTimeInterval(-125), path: path),
            "hapto": AttentionRecord(state: .waiting, message: nil, since: now.addingTimeInterval(-47), path: "hapto"),
        ]
    }

    // MARK: - Files

    /// Writes the project folder: a few sources, notes, and generated images,
    /// each with its own modification time so the recent lists have an order.
    static func makeProject(in parent: URL, now: Date) throws -> SnapshotFixtures {
        let root = parent.appendingPathComponent("vitra")
        let files: [(String, String, TimeInterval)] = [
            (".git/HEAD", "ref: refs/heads/main\n", 0),
            ("Package.swift", "// swift-tools-version: 6.0\nimport PackageDescription\n", 86_400 * 3),
            ("README.md", "# Vitra\n\nO cockpit do maestro.\n", 86_400 * 2),
            ("CHANGELOG.md", "## 0.4\n- ranking por tipo de tarefa\n", 3_600 * 5),
            ("docs/plan.md", "# Plano\n\n1. snapshots da interface\n2. revisão de design\n", 600),
            ("docs/notes.txt", "anotações soltas\n", 86_400 * 6),
            ("Sources/VitraApp/main.swift", "import AppKit\n\nlet application = NSApplication.shared\n", 7_200),
            ("Sources/VitraApp/Cockpit/ProjectView.swift", "final class ProjectView: NSView {}\n", 1_800),
            ("Sources/VitraPanel/PreviewPanel.swift", "public final class PreviewPanel: NSView {}\n", 14_400),
            ("Sources/VitraOrchestrator/Scoreboard.swift", "public enum Scoreboard {}\n", 28_800),
            ("Tests/VitraAppTests/CockpitModelTests.swift", "import Testing\n", 43_200),
            ("scripts/test.sh", "#!/bin/sh\nexec swift test\n", 86_400 * 4),
        ]
        let fileManager = FileManager.default
        for (relative, text, age) in files {
            let url = root.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let images: [(String, NSColor, NSColor, TimeInterval)] = [
            ("docs/screens/cockpit.png", NSColor(red: 0.91, green: 0.64, blue: 0.24, alpha: 1), NSColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 1), 300),
            ("docs/screens/ranking.png", NSColor(red: 0.44, green: 0.81, blue: 0.59, alpha: 1), NSColor(red: 0.1, green: 0.11, blue: 0.13, alpha: 1), 3_000),
            ("assets/icon.png", NSColor(red: 0.9, green: 0.39, blue: 0.35, alpha: 1), NSColor(red: 0.2, green: 0.22, blue: 0.27, alpha: 1), 20_000),
            ("assets/palette.png", NSColor(red: 0.4, green: 0.55, blue: 0.9, alpha: 1), NSColor(red: 0.9, green: 0.64, blue: 0.24, alpha: 1), 86_400),
        ]
        for (relative, from, to, age) in images {
            let url = root.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png(from: from, to: to).write(to: url)
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        return SnapshotFixtures(now: now, project: root)
    }

    /// A 160x120 diagonal gradient, so a thumbnail is something to look at.
    private static func png(from: NSColor, to: NSColor) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { throw SnapshotError.render("could not draw a fixture image") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGradient(starting: from, ending: to)?.draw(in: NSRect(x: 0, y: 0, width: 160, height: 120), angle: 315)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.render("could not encode a fixture image") }
        return data
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case render(String)

    var description: String {
        switch self {
        case let .render(reason): return reason
        }
    }
}

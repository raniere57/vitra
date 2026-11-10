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

    /// Eight workers across four kinds of task, with enough runs each for
    /// `Scoreboard` to rank them.
    func rankingScores() -> [ModelScore] {
        let table: [(WorkerCLI, String, String?, TaskKind, [Int?], Int, Double, Double)] = [
            (.opencode, "opencode/deepseek-v4.1-flash-free", nil, .explore, [4, 5, 4, 4, 5, 4], 0, 38, 0),
            (.claude, "claude-haiku-5-5", "low", .explore, [5, 5, 4, 5, 5], 0, 44, 0.012),
            (.claude, "claude-sonnet-5-5", "medium", .implement, [5, 4, 5, 5, 4], 0, 210, 0.19),
            (.opencode, "opencode/deepseek-v4.1-flash-free", nil, .implement, [3, 4, 2, 4, nil, nil], 1, 260, 0),
            (.cursor, "composer-2", nil, .implement, [nil, nil, nil], 0, 180, 0.08),
            (.claude, "claude-sonnet-5-5", "high", .review, [5, 4, 5, 5], 0, 95, 0.07),
            (.opencode, "opencode/glm-5-free", nil, .review, [3, 4, 3], 0, 120, 0),
            (.claude, "claude-haiku-5-5", "medium", .test, [4, 4, 5, 4], 0, 150, 0.03),
        ]
        var runs: [Run] = []
        for (cli, model, effort, kind, scores, failures, seconds, cost) in table {
            for (index, score) in scores.enumerated() {
                let failed = index < failures
                runs.append(run(
                    "\(runs.count)", model, cli, effort: effort, label: nil, kind: kind,
                    state: .finished(exitCode: failed ? 1 : 0), ago: Double(index + 1) * 3_600, took: seconds + Double(index) * 3,
                    cost: cost, tokens: (12_000, 1_500), score: failed ? nil : score, isError: failed
                ))
            }
        }
        return Scoreboard.scores(runs)
    }

    private func run(
        _ id: String, _ model: String, _ cli: WorkerCLI, effort: String? = nil, label: String?, kind: TaskKind,
        access: WorkerAccess = .read, state: Run.State = .finished(exitCode: 0), ago: TimeInterval, took: TimeInterval = 0,
        cost: Double = 0, tokens: (Int, Int) = (0, 0), score: Int? = nil, note: String? = nil, isError: Bool = false,
        answer: String? = nil
    ) -> Run {
        let started = now.addingTimeInterval(-ago)
        let isRunning = state == .running
        let hasOutput: Bool
        if case .finished = state { hasOutput = true } else { hasOutput = false }
        return Run(
            id: id,
            spec: WorkerSpec(
                cli: cli, model: model, prompt: label ?? "tarefa", directory: path, access: access,
                label: label, kind: kind, effort: effort, project: path
            ),
            state: state,
            pid: isRunning ? 4242 : nil,
            started: started,
            ended: isRunning ? nil : started.addingTimeInterval(took),
            output: hasOutput
                ? WorkerOutput(text: answer ?? "ok", isError: isError, costUSD: cost, inputTokens: tokens.0, outputTokens: tokens.1)
                : nil,
            errorTail: nil,
            rating: score.map { Rating(score: $0, note: note, rated: started.addingTimeInterval(took + 30)) }
        )
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

    var usage: UsageLabel? {
        MaestroStatus.label(SubscriptionUsage(sevenDay: 62, fiveHour: 18, updated: now), now: now)
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

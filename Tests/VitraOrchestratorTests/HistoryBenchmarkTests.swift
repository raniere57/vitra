import Foundation
import Testing
@testable import VitraOrchestrator

/// How long the history takes to read at the size the cockpit reads it.
///
/// Off by default: it writes 2,000 runs and is a measurement, not a check
/// that a change is right. `VITRA_BENCH=1 scripts/test.sh --filter HistoryBenchmark`
/// prints the numbers; the budgets are the ones the cockpit is built around.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VITRA_BENCH"] == "1"))
struct HistoryBenchmark {
    static let count = 2000

    @Test func theHistoryReadsWithinItsBudgets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try SyntheticRuns.write(Self.count, under: root)

        // Cold is a new process: nothing of the root in memory. The first look
        // has no index either and builds it; the next new process reads it.
        let fresh = { () -> Orchestrator in
            RunCache.forget(root)
            return Orchestrator(root: root, executables: Executables(paths: [:]))
        }
        let (all, coldAll) = time { fresh().recent(limit: 2000) }
        #expect(all.count == Self.count)
        let coldIndexed = time { fresh().recent(limit: 2000) }.1
        let coldRecent = time { fresh().recent(limit: 60) }.1
        let warm = fresh()
        _ = warm.recent(limit: 2000)
        let warmAll = best { _ = warm.recent(limit: 2000) }
        let warmRecent = best { _ = warm.recent(limit: 60) }
        let scores = best { _ = Scoreboard.scores(all) }
        let offers = Array(Set(Lineup.standard.hard + Lineup.standard.normal + Lineup.standard.easy))
        let pick = best {
            _ = WorkerPicker.pick(
                kind: .implement, access: .edit, needsCommands: true, history: all, offers: offers,
                installed: Set(WorkerCLI.allCases)
            )
        }

        let lines = [
            "recent(2000) cold, no index \(ms(coldAll))", "recent(2000) cold, indexed \(ms(coldIndexed))",
            "recent(2000) warm \(ms(warmAll))",
            "recent(60) cold \(ms(coldRecent))", "recent(60) warm \(ms(warmRecent))",
            "scores \(ms(scores))", "pick \(ms(pick))",
        ]
        print("HistoryBenchmark: " + lines.joined(separator: " · "))
        #expect(warmRecent < 0.005)
        #expect(warmAll < 0.060)
        #expect(coldAll < 1.5)
        #expect(coldIndexed < 1.5)
        #expect(scores < 0.040)
        #expect(pick < 0.025)
    }

    private func time<T>(_ body: () -> T) -> (T, TimeInterval) {
        let start = Date()
        let value = body()
        return (value, Date().timeIntervalSince(start))
    }

    /// The best of five: the machine is shared, and the slow runs measure it.
    private func best(_ body: () -> Void) -> TimeInterval {
        (0..<5).map { _ in time(body).1 }.min() ?? 0
    }

    private func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }
}

/// Finished runs written straight to disk, as a worker's shell would leave them.
enum SyntheticRuns {
    static let kinds: [TaskKind] = [.explore, .review, .implement, .test, .docs]
    static let models = [("claude", "sonnet", "high"), ("claude", "haiku", "low"), ("opencode", "opencode/glm-5.3-flash-free", nil)]

    /// Writes `count` runs, one a day back from `newest`, the newest first.
    @discardableResult
    static func write(_ count: Int, under root: URL, newest: Date = Date(), spacing: TimeInterval = 600) throws -> [String] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let id = String(format: "%08x", 0x1000_0000 + index)
            let started = newest.addingTimeInterval(-Double(index) * spacing)
            try write(id: id, index: index, started: started, under: root)
            return id
        }
    }

    static func write(id: String, index: Int, started: Date, under root: URL, audit: Bool = false) throws {
        let directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (cli, model, effort) = models[index % models.count]
        let kind = kinds[index % kinds.count]
        let spec = WorkerSpec(
            cli: WorkerCLI(rawValue: cli) ?? .claude, model: model, prompt: "piece \(index)", directory: "/tmp",
            access: audit ? .read : (kind == .implement ? .edit : .read), kind: kind, effort: effort,
            difficulty: Difficulty.allCases[index % 3], auditFocus: audit ? [.security] : nil
        )
        let record = RunRecord(
            spec: spec, started: started, pid: 99999, leaderStarted: nil,
            repository: nil, worktree: nil, branch: nil, baseCommit: nil,
            redoOf: index % 17 == 0 ? String(format: "%08x", 0x1000_0000 + index + 1) : nil
        )
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("run.json"))
        let exitCode: Int32 = index % 9 == 0 ? 1 : 0
        let ended = started.addingTimeInterval(Double(60 + index % 300))
        try Data("\(exitCode)\n".utf8).write(to: directory.appendingPathComponent("exit"))
        try FileManager.default.setAttributes([.modificationDate: ended], ofItemAtPath: directory.appendingPathComponent("exit").path)
        let output = WorkerOutput(
            text: index % 31 == 0 ? "out of quota: usage limit reached" : "answer \(index)",
            isError: exitCode != 0, costUSD: Double(index % 7) / 10, inputTokens: 100, outputTokens: 10
        )
        let summary = RunSummary(
            exitCode: exitCode, ended: ended, errorTail: nil, commitError: nil, worktreeSkipped: [], output: output
        )
        try JSONEncoder().encode(summary).write(to: directory.appendingPathComponent("summary.json"))
        try Data("piece \(index)".utf8).write(to: directory.appendingPathComponent("prompt"))
        try Data(String(repeating: "x", count: 2048).utf8).write(to: directory.appendingPathComponent("stdout"))
        if index % 3 == 0 {
            let rating = Rating(score: 1 + index % 5, note: nil, rated: ended)
            try JSONEncoder().encode(rating).write(to: directory.appendingPathComponent("rating.json"))
        }
        // The directory's own date is what `recent` orders by.
        try FileManager.default.setAttributes([.creationDate: started, .modificationDate: started], ofItemAtPath: directory.path)
    }
}

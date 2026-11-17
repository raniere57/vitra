import Foundation
import VitraOrchestrator

/// An editing worker's delivery: the commits its branch added on top of the
/// commit it started from. What the review reads its diff out of.
struct Delivery: Equatable, Sendable {
    let runID: String
    let label: String
    let worker: String
    let repository: String
    let branch: String
    let base: String
    let worktree: String?

    /// Only a run that got a branch and has stopped writing to it: while it
    /// runs, its work is not committed yet and the diff would be empty.
    init?(_ run: Run) {
        guard run.state != .running, let repository = run.repository, let branch = run.branch,
              let base = run.baseCommit else { return nil }
        self.init(
            runID: run.id, label: (run.spec.label ?? "").isEmpty ? run.spec.worker : run.spec.label ?? "",
            worker: run.spec.worker, repository: repository, branch: branch, base: base, worktree: run.worktree
        )
    }

    init(runID: String, label: String, worker: String, repository: String, branch: String, base: String, worktree: String?) {
        self.runID = runID
        self.label = label
        self.worker = worker
        self.repository = repository
        self.branch = branch
        self.base = base
        self.worktree = worktree
    }
}

/// Reads a delivery's changes with git. Blocking: always called off the
/// main thread.
enum DeliveryDiff {
    enum Outcome: Sendable {
        case files([DiffFile])
        /// The branch and the worktree are both gone: merged or discarded.
        case gone
        case failed(String)
    }

    static let goneText = "As mudanças já foram integradas ou descartadas."

    /// The commit the delivery ends at: its branch while it exists, else the
    /// head of its worktree, else nothing.
    static func tip(of delivery: Delivery) -> String? {
        if git(["rev-parse", "--verify", "--quiet", "refs/heads/\(delivery.branch)^{commit}"], in: delivery.repository) != nil {
            return delivery.branch
        }
        guard let tree = delivery.worktree, FileManager.default.fileExists(atPath: tree),
              let head = git(["rev-parse", "--verify", "--quiet", "HEAD"], in: tree)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty
        else { return nil }
        return head
    }

    static func load(_ delivery: Delivery) -> Outcome {
        guard let tip = tip(of: delivery) else { return .gone }
        guard let text = git(["diff", "--no-color", "--no-ext-diff", "-U3", "\(delivery.base)..\(tip)"], in: delivery.repository) else {
            return .failed("Não deu para ler o diff de \(delivery.branch).")
        }
        return .files(UnifiedDiff.parse(text))
    }

    /// "+a −d · n arquivos", from git's own count: cheap enough for a row
    /// that has only just been opened. Nil when the delivery is gone.
    static func summary(_ delivery: Delivery) -> String? {
        guard let tip = tip(of: delivery),
              let stat = git(["diff", "--numstat", "\(delivery.base)..\(tip)"], in: delivery.repository)
        else { return nil }
        let lines = stat.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return "sem mudanças" }
        let counts = lines.map { line -> (Int, Int) in
            let fields = line.split(separator: "\t")
            // A binary file counts as "-": no lines.
            return (fields.first.flatMap { Int($0) } ?? 0, fields.dropFirst().first.flatMap { Int($0) } ?? 0)
        }
        return DiffRows.summary(
            added: counts.reduce(0) { $0 + $1.0 }, removed: counts.reduce(0) { $0 + $1.1 }, files: lines.count
        )
    }

    private static func git(_ arguments: [String], in directory: String) -> String? {
        GitHistory.run("/usr/bin/env", ["git"] + arguments, in: directory).map { String(decoding: $0, as: UTF8.self) }
    }
}

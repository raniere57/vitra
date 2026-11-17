import Foundation
import VitraOrchestrator

/// What the maestro is told when a worker stops. A maestro sitting in
/// agent_wait does nothing else and cannot hear the user: told when the work
/// is back, it is free to go on, or to end its turn, while workers run.
enum WorkerNotice {
    /// Runs that were going in `before` and have stopped by themselves. A
    /// cancelled one was stopped by someone who already knows.
    static func stopped(_ runs: [Run], wasRunning before: Set<String>) -> [Run] {
        runs.filter { before.contains($0.id) && $0.state != .running && $0.state != .cancelled }
    }

    static func text(stopped runs: [Run]) -> String? {
        guard let first = runs.first else { return nil }
        guard runs.count > 1 else {
            return "[Vitra] O operário \(name(first)) terminou. Leia a entrega com agent_wait."
        }
        return "[Vitra] Operários terminaram: \(runs.map(name).joined(separator: ", ")). Leia as entregas com agent_wait."
    }

    /// A worker still going past its time limit is only cancelled when read.
    static func text(overdue run: Run) -> String {
        "[Vitra] O operário \(name(run)) passou do limite de \(minutes(run)) min e segue rodando. Chame agent_wait para encerrá-lo."
    }

    static func minutes(_ run: Run) -> Int { run.spec.minutes ?? Orchestrator.defaultMinutes }

    private static func name(_ run: Run) -> String {
        guard let label = run.spec.label, !label.isEmpty else { return run.id }
        return "\(run.id) (\(label))"
    }
}

import Foundation
import VitraOrchestrator

/// Watches the workers on disk and reports them to the cockpit.
///
/// At rest it costs nothing: there is no timer, only a watch on the runs
/// directory that fires when a worker is spawned. A one-second tick exists
/// only while something is running, to catch workers finishing and to move
/// their clocks, and stops with the last of them.
final class RunFeed: @unchecked Sendable {
    private static let listed = 60
    /// How far back the ranking looks.
    private static let scored = 2000
    /// When to look again after a run directory appears.
    private static let recordDelays: [TimeInterval] = [0.3, 1.5]

    private let orchestrator: Orchestrator
    private let root: URL
    private let queue = DispatchQueue(label: "dev.vitra.runfeed", qos: .utility)
    private var watch: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    /// Called on the main queue with the newest runs first.
    var onChange: (@MainActor @Sendable ([Run]) -> Void)?

    init(orchestrator: Orchestrator = Orchestrator(), root: URL = Orchestrator.defaultRoot) {
        self.orchestrator = orchestrator
        self.root = root
    }

    func start() {
        queue.async { [self] in
            // The directory may not exist before the first worker ever runs,
            // and a watch needs something to hold. Created as the orchestrator
            // would create it: the user's alone.
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let descriptor = open(root.path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: .write,
                    queue: queue
                )
                source.setEventHandler { [weak self] in self?.directoryChanged() }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                watch = source
            }
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            watch?.cancel()
            watch = nil
            timer?.cancel()
            timer = nil
        }
    }

    /// Works out how each model has done, from the whole history on disk.
    ///
    /// On request rather than on every tick: it reads every run there is, and
    /// nothing needs it until someone opens the ranking.
    func scores(_ completion: @escaping @MainActor @Sendable ([ModelScore]) -> Void) {
        queue.async { [self] in
            let scores = Scoreboard.scores(orchestrator.recent(limit: Self.scored))
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(scores) } }
        }
    }

    /// Stops the given workers, then reports what is left.
    func cancel(_ ids: [String]) {
        queue.async { [self] in
            for id in ids { try? orchestrator.cancel(id) }
            refresh()
        }
    }

    /// A worker's directory appears before its record does: the orchestrator
    /// creates the one, starts the process, and only then writes the other.
    /// Looking once, at the instant the directory shows up, would find no run
    /// and nothing would ever look again — the record lands in a subdirectory
    /// this watch does not cover. So the look is repeated once the record has
    /// had time to be written.
    private func directoryChanged() {
        refresh()
        for delay in Self.recordDelays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        let runs = orchestrator.recent(limit: Self.listed)
        setTicking(runs.contains { $0.state == .running })
        let handler = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(runs) } }
    }

    private func setTicking(_ ticking: Bool) {
        guard ticking != (timer != nil) else { return }
        guard ticking else {
            timer?.cancel()
            timer = nil
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        timer = source
    }
}

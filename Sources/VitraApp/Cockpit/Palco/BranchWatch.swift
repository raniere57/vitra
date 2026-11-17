import Foundation

/// Tells the Palco which local branches exist, so that a delivery's branch
/// vanishing — merged and deleted — can be seen.
///
/// Event-driven: it watches the repository's git directory and its
/// `refs/heads/vitra`, and asks git (off the main thread) when those change,
/// never more than once in `minimumGap`. With nothing to watch for it is
/// stopped, and then it costs nothing. Main thread only.
@MainActor
final class BranchWatch {
    static let minimumGap: TimeInterval = 5
    private static let settle: TimeInterval = 0.8

    private let path: String
    private let onBranches: @MainActor (Set<String>) -> Void
    private var watches: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var lastCheck = Date.distantPast
    private var generation = 0
    private(set) var isActive = false

    init(path: String, onBranches: @escaping @MainActor (Set<String>) -> Void) {
        self.path = path
        self.onBranches = onBranches
    }

    deinit {
        // The sources hold their own descriptors and close them on cancel.
        watches.forEach { $0.cancel() }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        generation += 1
        let (path, generation) = (self.path, self.generation)
        DispatchQueue.global(qos: .utility).async {
            let git = GitHistory.gitCommonDirectory(in: path)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, self.generation == generation, let git else { return }
                    for target in [git, git + "/refs/heads", git + "/refs/heads/vitra"] { self.watch(target) }
                }
            }
        }
        changed()
    }

    func stop() {
        isActive = false
        watches.forEach { $0.cancel() }
        watches.removeAll()
        pending?.cancel()
        pending = nil
    }

    private func watch(_ target: String) {
        let descriptor = open(target, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watches.append(source)
    }

    /// One look for a burst of events, and never sooner than `minimumGap` after the last.
    private func changed() {
        guard isActive, pending == nil else { return }
        let wait = max(Self.settle, Self.minimumGap - Date().timeIntervalSince(lastCheck))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (lastCheck == .distantPast ? 0 : wait), execute: work)
    }

    private func check() {
        pending = nil
        guard isActive else { return }
        lastCheck = Date()
        let path = self.path
        DispatchQueue.global(qos: .utility).async {
            let output = GitHistory.run("/usr/bin/git", ["branch", "--list", "--format=%(refname:short)"], in: path)
            guard let output else { return }
            let names = Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onBranches(names) } }
        }
    }
}

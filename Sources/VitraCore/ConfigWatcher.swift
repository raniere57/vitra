import CoreServices
import Foundation

/// Reloads the configuration when the file changes.
///
/// Watches the *directory*, not the file: editors save by writing a temporary
/// file and renaming it over the original, which replaces the inode and leaves a
/// file watch pointing at something nobody will ever write to again.
public final class ConfigWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable (Config, [String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.vitra.config", qos: .utility)

    public init(url: URL = Config.path, onChange: @escaping @Sendable (Config, [String]) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.reload()
        }

        // 0.2s of latency coalesces the burst of events a single save produces.
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Re-reads and reports, but only when something actually changed: a save
    /// touches the whole directory, and redrawing every window for an unrelated
    /// file would be a waste.
    private func reload() {
        let (config, problems) = Config.load(from: url)
        guard config != lastDelivered else { return }
        lastDelivered = config
        onChange(config, problems)
    }

    private var lastDelivered: Config?
}

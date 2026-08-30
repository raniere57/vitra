import Foundation

/// Where pasted and dropped files are kept so the agent can read them by path.
///
/// The agent takes file paths typed into its prompt, so an image on the
/// clipboard has to become a file on disk first. These files are transient by
/// design: they are written for one conversation and swept afterwards.
public struct AttachmentStore: Sendable {
    public let directory: URL

    /// How long a written attachment is kept before the next launch sweeps it.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public init(directory: URL = Vitra.supportDirectory.appendingPathComponent("attachments", isDirectory: true)) {
        self.directory = directory
    }

    /// Writes `data` under a timestamped name and returns the file's URL.
    ///
    /// The name is sortable and free of characters that need escaping, so a
    /// stored attachment never needs quoting when it is pasted.
    @discardableResult
    public func store(_ data: Data, extension pathExtension: String, prefix: String = "paste") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Two pastes inside the same millisecond would otherwise produce the
        // same name and the second would silently replace the first, so the
        // write refuses to overwrite and a counter is appended until it lands.
        let stamp = Self.timestamp()
        for attempt in 0... {
            let suffix = attempt == 0 ? "" : "-\(attempt + 1)"
            let url = directory.appendingPathComponent("\(prefix)-\(stamp)\(suffix).\(pathExtension)")
            do {
                // Not atomic: Foundation rejects that combination, and an
                // atomic write would rename over the name this is claiming.
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        // Unreachable: the loop only exits by returning or throwing.
        throw CocoaError(.fileWriteUnknown)
    }

    /// Deletes attachments older than `retention`.
    ///
    /// Failures are ignored on purpose: a file that cannot be swept is not worth
    /// interrupting a session over, and the next launch tries again.
    public func purgeExpired(now: Date = Date(), retention: TimeInterval = AttachmentStore.retention) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > retention {
                try? manager.removeItem(at: entry)
            }
        }
    }

    /// A sortable, quote-free timestamp: `20260830-184512-337`.
    ///
    /// Colons are deliberately absent: they are legal in POSIX paths but the
    /// Finder displays them as slashes, which makes such a name confusing to
    /// read back.
    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

/// A file about to be handed to the agent, with what the UI needs to show it.
public struct Attachment: Sendable, Equatable {
    public let url: URL
    /// True when the file was written by Vitra rather than pointed at by the user.
    public let isTemporary: Bool

    public init(url: URL, isTemporary: Bool) {
        self.url = url
        self.isTemporary = isTemporary
    }

    public var displayName: String { url.lastPathComponent }

    /// The absolute path, with symlinks left intact.
    ///
    /// Resolved but not canonicalised: `/tmp/x` resolves to `/private/tmp/x`, and
    /// showing the user a path they did not choose is worse than following the
    /// link they did.
    public var path: String { url.standardizedFileURL.path }
}

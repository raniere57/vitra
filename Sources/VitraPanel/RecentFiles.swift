import Foundation
import UniformTypeIdentifiers

/// The files of one kind anywhere in a project, most recently changed first:
/// the image just generated or the video just rendered is at the top, without
/// anyone having to know which folder it was written to.
public enum RecentFiles {
    public enum Kind: String, CaseIterable, Sendable {
        case image, video, text
    }

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let modified: Date
    }

    /// Folders that hold what was downloaded or built, not what was made:
    /// thousands of files that would bury the handful being looked for.
    static let skipped: Set<String> = [
        "node_modules", "dist", "build", "DerivedData", "Pods", "vendor", "target", "__pycache__", "venv",
    ]
    /// Where the search stops however big the project is.
    private static let mostVisited = 60000

    public static func kind(of url: URL) -> Kind? {
        // The system reads .ts as an MPEG transport stream; in a project it
        // is TypeScript, every time.
        if ["ts", "tsx", "mts", "cts"].contains(url.pathExtension.lowercased()) { return .text }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audiovisualContent) { return type.conforms(to: .audio) ? nil : .video }
        if type.conforms(to: .text) { return .text }
        return nil
    }

    /// Where Claude Code keeps a project's scratchpads, one per conversation:
    /// what an agent made "to show you" lands there, outside the project.
    public static func scratchpads(for project: URL) -> URL {
        let slug = project.path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true).appendingPathComponent(slug)
    }

    /// The project's files and its conversations' scratchpads, newest first.
    public static func find(in project: URL, alsoIn extra: [URL], kind: Kind, limit: Int = 120) -> [Entry] {
        let all = ([project] + extra.filter { FileManager.default.fileExists(atPath: $0.path) })
            .flatMap { find(in: $0, kind: kind, limit: limit) }
        return Array(all.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Reads the disk; call it off the main thread.
    public static func find(in root: URL, kind: Kind, limit: Int = 120) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return []
        }
        var found: [Entry] = []
        var visited = 0
        for case let url as URL in walk {
            visited += 1
            if visited > mostVisited { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                // Hidden folders too: .git alone is most of a repository.
                let name = url.lastPathComponent
                if name.hasPrefix(".") || skipped.contains(name) { walk.skipDescendants() }
                continue
            }
            guard self.kind(of: url) == kind, let modified = values?.contentModificationDate else { continue }
            found.append(Entry(url: url, modified: modified))
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}

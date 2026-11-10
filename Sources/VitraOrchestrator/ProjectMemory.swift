import CryptoKit
import Foundation

/// The notes agents leave about a project for the agents that come after them.
///
/// One file per project, one line per note. A worker starts from zero, so
/// without this the maestro explains the project again in every prompt; with
/// it, what one agent learned is read by the next before it starts.
///
///     <root>/<hash of the project path>/memory.md
public struct ProjectMemory: Sendable {
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vitra/projects")
    }

    /// Notes kept per project. Older ones fall off the top: the file must not
    /// grow without limit, and a stale note is worth less than a fresh one.
    static let maxLines = 200
    static let maxNoteLength = 300
    private static let hashLength = 16

    private let root: URL

    public init(root: URL = ProjectMemory.defaultRoot) {
        self.root = root
    }

    /// The notes of `project`, one per line, oldest first. Empty when there are none.
    public func read(project: String) -> String {
        let text = (try? String(contentsOf: file(for: project), encoding: .utf8)) ?? ""
        return lines(of: text).joined(separator: "\n")
    }

    /// Appends a note dated `now`, attributed to `author`.
    ///
    /// The note must be one line of at most `maxNoteLength` characters, once
    /// trimmed. A refused note writes nothing.
    public func add(_ note: String, author: String, project: String, now: Date = Date()) throws(ProjectMemoryError) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        guard !text.contains(where: \.isNewline) else { throw .multiline }
        guard text.count <= Self.maxNoteLength else { throw .tooLong(text.count) }

        let entry = "- \(Self.day(now)) [\(author)] \(text)"
        let kept = (lines(of: (try? String(contentsOf: file(for: project), encoding: .utf8)) ?? "") + [entry])
            .suffix(Self.maxLines)
        do {
            try FileManager.default.createDirectory(
                at: directory(for: project),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: file(for: project), options: .atomic)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
    }

    // MARK: - On disk

    private func directory(for project: String) -> URL {
        let digest = SHA256.hash(data: Data(project.utf8))
        let key = digest.prefix(Self.hashLength / 2).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key)
    }

    private func file(for project: String) -> URL {
        directory(for: project).appendingPathComponent("memory.md")
    }

    /// The non-empty lines of a memory file.
    private func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The day of `date` in the local calendar, as YYYY-MM-DD.
    private static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // ponytail: read-then-rewrite, so two agents adding at the same instant can
    // drop one note. Fine while agents add a note now and then; take a flock on
    // the file if they start writing in bulk.
}

/// Why a note was refused. The description is what the agent is shown.
public enum ProjectMemoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case multiline
    case tooLong(Int)
    case unwritable(String)

    public var description: String {
        switch self {
        case .empty: return "the note is empty"
        case .multiline: return "a note must be one line"
        case let .tooLong(count): return "a note is at most \(ProjectMemory.maxNoteLength) characters, this one has \(count)"
        case let .unwritable(reason): return "could not save the note: \(reason)"
        }
    }
}

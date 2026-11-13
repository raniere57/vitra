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
    static let maxAuthorLength = 40
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

        let entry = "- \(Self.day(now)) [\(Self.safeAuthor(author))] \(text)"
        do {
            try FileManager.default.createDirectory(
                at: directory(for: project),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // The lock covers the whole read-modify-write, so two adds at once
            // cannot both read the same file and lose one note.
            let descriptor = open(lockFile(for: project).path, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }

            let existing = (try? String(contentsOf: file(for: project), encoding: .utf8)) ?? ""
            let kept = (lines(of: existing) + [entry]).suffix(Self.maxLines)
            try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: file(for: project), options: .atomic)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
    }

    /// The author as one safe token: ASCII letters, digits, `-`, `_`, `.`, at
    /// most `maxAuthorLength` characters. Anything else is dropped, so an author
    /// cannot add a line or close the bracket. Empty becomes "agent".
    public static func safeAuthor(_ author: String) -> String {
        let kept = author.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
        }
        let token = String(kept.prefix(maxAuthorLength))
        return token.isEmpty ? "agent" : token
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

    private func lockFile(for project: String) -> URL {
        directory(for: project).appendingPathComponent("memory.lock")
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

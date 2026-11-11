import Foundation
import os

/// The user's escalação: for each difficulty, the workers they want, in order.
///
/// It is the prior the picker starts from — the user knows which workers are
/// fast and capable before any record says so. The record only demotes a
/// worker that keeps falling short, and a learning turn gives it its place
/// back. Kept in `~/.vitra/lineup.json`; a missing or broken file is the
/// default.
public struct Lineup: Codable, Equatable, Sendable {
    public typealias Worker = ModelCatalog.Offer

    /// The shape of the file. A file of another version is not read.
    public static let currentVersion = 1

    public var version: Int
    public var hard: [Worker]
    public var normal: [Worker]
    public var easy: [Worker]

    public init(hard: [Worker], normal: [Worker], easy: [Worker]) {
        version = Self.currentVersion
        self.hard = hard
        self.normal = normal
        self.easy = easy
    }

    /// What a user who has not said otherwise gets.
    public static let standard = Lineup(
        hard: [
            Worker(cli: .claude, model: "opus", effort: "low"),
            Worker(cli: .claude, model: "sonnet", effort: "high"),
            Worker(cli: .claude, model: "haiku", effort: "high"),
            Worker(cli: .cursor, model: "grok-4.7-high-fast", effort: nil),
        ],
        normal: [
            Worker(cli: .cursor, model: "cursor-grok-4.6-low-fast", effort: nil),
            Worker(cli: .claude, model: "haiku", effort: "low"),
            Worker(cli: .opencode, model: "opencode/glm-5.3-flash-free", effort: nil),
            Worker(cli: .opencode, model: "opencode/deepseek-v4.1-flash-free", effort: nil),
            Worker(cli: .cursor, model: "grok-4.7-low-fast", effort: nil),
        ],
        easy: [
            Worker(cli: .cursor, model: "cursor-grok-4.6-low-fast", effort: nil),
            Worker(cli: .opencode, model: "opencode/glm-5.3-flash-free", effort: nil),
            Worker(cli: .claude, model: "haiku", effort: "low"),
        ]
    )

    public func tier(_ difficulty: Difficulty) -> [Worker] {
        switch difficulty {
        case .hard: return hard
        case .normal: return normal
        case .easy: return easy
        }
    }

    /// This lineup with `difficulty`'s tier replaced.
    public func with(_ difficulty: Difficulty, _ workers: [Worker]) -> Lineup {
        var copy = self
        switch difficulty {
        case .hard: copy.hard = workers
        case .normal: copy.normal = workers
        case .easy: copy.easy = workers
        }
        return copy
    }

    // MARK: File

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vitra/lineup.json")
    }

    /// The last file read, by path and modification date: every spawn asks.
    private static let cache = OSAllocatedUnfairLock<[String: (Date, Lineup)]>(initialState: [:])

    /// The lineup in `url`, or the default when the file is missing, broken or
    /// of another version.
    public static func load(from url: URL = defaultURL) -> Lineup {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return standard }
        if let (date, lineup) = cache.withLock({ $0[url.path] }), date == modified { return lineup }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Lineup.self, from: $0) }
        let lineup = read.flatMap { $0.version == currentVersion ? $0 : nil } ?? standard
        cache.withLock { $0[url.path] = (modified, lineup) }
        return lineup
    }

    /// Writes the lineup to `url` at once, whole or not at all.
    public func save(to url: URL = Lineup.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Why the picker chose a worker: a code for the UI, the text for the maestro.
public struct PickReason: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        /// A worker of the lineup; `position` says which.
        case lineup
        /// Every fifth piece: a worker that has no record yet, or a demoted one.
        case learning
        /// Not in the lineup: chosen by its record.
        case record
        /// Not in the lineup and no record to go by.
        case cheapest
    }

    /// What kept the lineup's earlier worker out.
    public enum Cause: String, Codable, Sendable {
        case quota, signedOut, down, resting, demoted, slow, unavailable
    }

    public let code: Code
    public let text: String
    /// 1-based place in the tier, for `.lineup`.
    public var position: Int? = nil
    /// The first lineup worker passed over, as a short model name, and why.
    public var passed: String? = nil
    public var cause: Cause? = nil

    public init(code: Code, text: String, position: Int? = nil, passed: String? = nil, cause: Cause? = nil) {
        self.code = code
        self.text = text
        self.position = position
        self.passed = passed
        self.cause = cause
    }
}

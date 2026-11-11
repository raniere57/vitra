import Foundation
import os

/// Which worker CLIs the user lets Vitra delegate to. Kept in
/// `~/.vitra/providers.json`; a missing, broken or other-version file, or one
/// that switches every CLI off, means every CLI is on — the picker is never
/// left with nobody by a file.
public struct ProviderSwitches: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// The CLIs switched off, in `WorkerCLI.allCases` order.
    public private(set) var off: [WorkerCLI]

    public init(off: Set<WorkerCLI> = []) {
        version = Self.currentVersion
        self.off = WorkerCLI.allCases.filter(off.contains)
    }

    public static let allOn = ProviderSwitches()

    public func isOn(_ cli: WorkerCLI) -> Bool { !off.contains(cli) }

    /// Why a switch was refused. The text is shown beside the switch.
    public enum Refusal: Error, Equatable, Sendable {
        case lastOne(WorkerCLI)

        public var text: String {
            switch self {
            case let .lastOne(cli):
                return "\(cli.rawValue) é o último fornecedor instalado e ligado: sem ele a Vitra não teria a quem delegar."
            }
        }
    }

    /// These switches with `cli` turned on or off. Turning off the last CLI
    /// that is installed and on is refused.
    public func setting(_ cli: WorkerCLI, on: Bool, installed: Set<WorkerCLI>) throws(Refusal) -> ProviderSwitches {
        var off = Set(self.off)
        if on { off.remove(cli) } else { off.insert(cli) }
        if !on, installed.contains(cli), installed.isSubset(of: off) { throw .lastOne(cli) }
        return ProviderSwitches(off: off)
    }

    // MARK: File

    /// `VITRA_PROVIDERS_FILE` overrides the place, so a test run never reads
    /// the user's own switches.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["VITRA_PROVIDERS_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vitra/providers.json")
    }

    /// The last file read, by path and modification date: every pick asks.
    private static let cache = OSAllocatedUnfairLock<[String: (Date, ProviderSwitches)]>(initialState: [:])

    public static func load(from url: URL = defaultURL) -> ProviderSwitches {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return allOn }
        if let (date, switches) = cache.withLock({ $0[url.path] }), date == modified { return switches }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ProviderSwitches.self, from: $0) }
        let valid = read.flatMap { $0.version == currentVersion && $0.off.count < WorkerCLI.allCases.count ? $0 : nil }
        let switches = valid.map { ProviderSwitches(off: Set($0.off)) } ?? allOn
        cache.withLock { $0[url.path] = (modified, switches) }
        return switches
    }

    /// Writes the switches to `url` at once, whole or not at all.
    public func save(to url: URL = ProviderSwitches.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

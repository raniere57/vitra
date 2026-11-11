import Foundation

/// The models a worker can be asked to run on.
public enum ModelCatalog {
    /// What is installed and what each CLI said it can run.
    public struct Listing: Sendable {
        public let claude: Bool
        /// Every model opencode listed, or nil when it is not installed.
        public let openCode: [String]?
        /// The lines `agy models` printed, or nil when it is not installed.
        public let gemini: [String]?
        /// The lines `cursor-agent models` printed, or nil when it is not installed.
        public let cursor: [String]?

        public init(claude: Bool, openCode: [String]?, gemini: [String]?, cursor: [String]?) {
            self.claude = claude
            self.openCode = openCode
            self.gemini = gemini
            self.cursor = cursor
        }

        /// Whether every CLI that is installed answered with a list. One that
        /// is installed and listed nothing failed, and the listing is not
        /// worth keeping; with nothing installed at all there is nothing to keep.
        var isComplete: Bool {
            let answers = [openCode, gemini, cursor].compactMap { $0 }
            return (claude || !answers.isEmpty) && answers.allSatisfy { !$0.isEmpty }
        }
    }

    /// The Claude workers on offer: each model with the efforts it may run at.
    ///
    /// A short, deliberate list. Sonnet at high and Opus at low are the two
    /// strong workers, Haiku at three efforts the cheap ones; every other
    /// pairing costs more subscription than it returns as a worker, and Opus
    /// and Fable at full effort are what the maestro itself runs on.
    public static let claudeWorkers: [(model: String, efforts: [String])] = [
        ("haiku", ["low", "medium", "high"]),
        ("sonnet", ["high"]),
        ("opus", ["low"]),
    ]

    /// Every effort a CLI might be asked for.
    public static let efforts = ["minimal", "low", "medium", "high", "xhigh", "max"]

    private static var claudeOffer: String {
        claudeWorkers.map { worker in
            let efforts = worker.efforts.count > 1
                ? worker.efforts.dropLast().joined(separator: ", ") + " or " + (worker.efforts.last ?? "")
                : worker.efforts.first ?? ""
            return "\(worker.model) at \(efforts)"
        }.joined(separator: "; ")
    }

    /// Why `cli` may not be asked for this model at this effort, or nil when
    /// it may.
    static func problem(with cli: WorkerCLI, model: String, effort: String?) -> String? {
        switch cli {
        case .claude:
            let offered = claudeWorkers.first { $0.model == model }?.efforts.contains(effort ?? "") ?? false
            return offered ? nil : "claude workers are \(claudeOffer) — not \(model) at \(effort ?? "no effort")"
        case .opencode:
            return isFreeOpenCodeModel(model)
                ? nil
                : "opencode is limited to its free models for now: use one named opencode/…-free, not '\(model)'"
        case .gemini:
            // With the effort in the id: agy runs a bare id at whatever
            // effort it defaults to, and the run would be filed under none.
            let hasEffort = ["-low", "-medium", "-high"].contains { model.hasSuffix($0) }
            guard model.hasPrefix("gemini-"), hasEffort else {
                return "gemini workers run Gemini models with the effort in the id, such as gemini-3.8-flash-low: not '\(model)'"
            }
            // The effort is part of agy's model id, as in gemini-3.8-flash-high.
            return effort == nil ? nil : "gemini's effort is part of the model id, as in gemini-3.8-flash-high: pass no effort"
        case .cursor:
            guard isGrok(model) else {
                return "cursor is limited to its Grok models, such as grok-4.7-low: not '\(model)'"
            }
            return effort == nil ? nil : "cursor's effort is part of the model id, as in grok-4.7-high: pass no effort"
        }
    }

    /// Whether a cursor model id names a Grok. Cursor reaches many models on
    /// one subscription; only the Groks are to be used as workers.
    static func isGrok(_ model: String) -> Bool {
        model.lowercased().contains("grok")
    }


    /// One worker the catalogue offers: a CLI, a model, and the effort it runs at.
    public struct Offer: Hashable, Sendable, Codable {
        public let cli: WorkerCLI
        public let model: String
        public let effort: String?

        public init(cli: WorkerCLI, model: String, effort: String?) {
            self.cli = cli
            self.model = model
            self.effort = effort
        }

        /// The worker as the orchestrating model names it, such as `claude haiku (high)`.
        public var name: String {
            "\(cli.rawValue) \(model)" + (effort.map { " (\($0))" } ?? "")
        }
    }

    /// Every worker `listing` offers, on the same terms `summary` states them.
    public static func offers(_ listing: Listing) -> [Offer] {
        var offers: [Offer] = []
        if listing.claude {
            offers += claudeWorkers.flatMap { worker in
                worker.efforts.map { Offer(cli: .claude, model: worker.model, effort: $0) }
            }
        }
        offers += (listing.openCode ?? []).filter(isFreeOpenCodeModel).map { Offer(cli: .opencode, model: $0, effort: nil) }
        offers += geminiIds(listing.gemini ?? []).map { Offer(cli: .gemini, model: $0, effort: nil) }
        offers += cursorGroks(listing.cursor ?? []).map { Offer(cli: .cursor, model: $0, effort: nil) }
        return offers
    }

    private static let listingTimeout: TimeInterval = 20
    /// How long a listing is reused before the CLIs are asked again.
    static let cacheLifetime: TimeInterval = 600

    /// The last listing, kept so a tool that needs it often does not wait
    /// several seconds per call. Reused only for the same executables.
    private final class ListingCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (paths: [WorkerCLI: String], at: Date, listing: Listing)?

        func listing(for paths: [WorkerCLI: String], now: Date) -> Listing? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry, entry.paths == paths, now.timeIntervalSince(entry.at) < cacheLifetime else { return nil }
            return entry.listing
        }

        func store(_ listing: Listing, for paths: [WorkerCLI: String], at now: Date) {
            lock.lock()
            defer { lock.unlock() }
            entry = (paths, now, listing)
        }
    }
    private static let listingCache = ListingCache()

    /// `listing`, reused for `cacheLifetime` seconds when the executables are
    /// the same. Blocks like `listing`: call it off the cooperative pool.
    ///
    /// The lock is held only to read or write the cache, never while the CLIs
    /// are asked, which takes seconds. A listing in which an installed CLI
    /// listed nothing — signed out, timed out, errored — is returned but not
    /// kept: the next call asks again instead of serving the gap for ten
    /// minutes.
    public static func cachedListing(_ executables: Executables, now: Date = Date()) -> Listing {
        if let cached = listingCache.listing(for: executables.paths, now: now) { return cached }
        let fresh = listing(executables)
        if fresh.isComplete { listingCache.store(fresh, for: executables.paths, at: now) }
        return fresh
    }

    /// What one CLI lists, asked afresh: nil when it is not installed, empty
    /// when it answered with an error or nothing (signed out, most often).
    /// Claude lists nothing; its workers are fixed. Blocks like `listing`.
    public static func lines(of cli: WorkerCLI, _ executables: Executables) -> [String]? {
        guard let path = executables.paths[cli] else { return nil }
        return cli == .claude ? [] : modelLines(output(of: path, arguments: ["models"]))
    }

    /// Keeps `listing`, made from `lines(of:)`, as `cachedListing` would have.
    public static func remember(_ listing: Listing, for executables: Executables, now: Date = Date()) {
        if listing.isComplete { listingCache.store(listing, for: executables.paths, at: now) }
    }

    /// Whether opencode may be asked for `model`.
    ///
    /// opencode reaches paid providers too, billed by the token. Until the
    /// user says otherwise only the models its own provider gives away are
    /// delegated to, and those are the ones it names `opencode/…-free`.
    ///
    /// ponytail: the rule is a constant. Move it to the config file when
    /// someone wants a paid model as a worker.
    public static func isFreeOpenCodeModel(_ model: String) -> Bool {
        model.hasPrefix("opencode/") && model.hasSuffix("-free")
    }

    /// Asks every installed CLI that can list its models to do so.
    ///
    /// Blocks until they answer or time out: call it off the cooperative pool.
    public static func listing(_ executables: Executables) -> Listing {
        Listing(
            claude: executables.paths[.claude] != nil,
            openCode: executables.paths[.opencode].map { modelLines(output(of: $0, arguments: ["models"])) },
            gemini: executables.paths[.gemini].map { modelLines(output(of: $0, arguments: ["models"])) },
            cursor: executables.paths[.cursor].map { modelLines(output(of: $0, arguments: ["models"])) }
        )
    }

    /// The lines of a CLI's model listing, or none when it answered with an
    /// error instead of a list.
    ///
    /// Every line is kept: cursor lists its Groks past the hundredth line, and
    /// `summary` does the choosing. Zero-width spaces are trimmed with the
    /// whitespace, or an id would carry an invisible tail and fail to match.
    static func modelLines(_ output: String) -> [String] {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let trimmed = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))
        let lines = plain
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: trimmed) }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("Error") != true else { return [] }
        return lines
    }

    /// What `executable` prints on stdout when run with `arguments`.
    private static func output(of executable: String, arguments: [String]) -> String {
        // The listing goes to a file, not a pipe. A pipe is only at its end
        // once every process holding it has let go, and these CLIs talk to
        // background services that may outlive them; a file is read when the
        // CLI itself has exited, whoever else is still around.
        let listing = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-models-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: listing.path, contents: nil),
              let output = try? FileHandle(forWritingTo: listing)
        else { return "" }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: listing)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Orchestrator.workerEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // An error such as "Authentication required" may arrive on either
        // stream; with both in the file it is recognised wherever it lands.
        process.standardError = output
        guard (try? process.run()) != nil else { return "" }

        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + listingTimeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        return String(decoding: (try? Data(contentsOf: listing)) ?? Data(), as: UTF8.self)
    }

    /// The gemini model ids in a listing. Each line is "id<tab>Name"; the id is
    /// what the CLI takes.
    static func geminiIds(_ lines: [String]) -> [String] {
        lines
            .map { $0.components(separatedBy: "\t").first ?? $0 }
            .filter { $0.hasPrefix("gemini-") && !$0.contains(" ") }
    }

    /// The Grok ids in a cursor listing. Each line is "id - Name"; the id is
    /// what the CLI takes.
    static func cursorGroks(_ lines: [String]) -> [String] {
        lines
            .map { $0.components(separatedBy: " - ").first ?? $0 }
            .filter { isGrok($0) && !$0.contains(" ") }
    }

    /// The catalogue as text for the orchestrating model.
    public static func summary(_ listing: Listing) -> String {
        var lines: [String] = []

        lines.append(listing.claude
            ? "cli \"claude\" (Claude subscription) — a model and an effort together: \(claudeOffer)."
            : "cli \"claude\": not installed.")

        if let openCode = listing.openCode {
            let free = openCode.filter(isFreeOpenCodeModel)
            lines.append(free.isEmpty
                ? "cli \"opencode\": installed, but it listed no free models. Check that it is signed in."
                : "cli \"opencode\" (free models only; effort optional): \(free.joined(separator: ", "))")
        } else {
            lines.append("cli \"opencode\": not installed.")
        }

        if let gemini = listing.gemini {
            let ids = geminiIds(gemini)
            lines.append(ids.isEmpty
                ? "cli \"gemini\": installed, but it listed no Gemini models. Sign in by running agy once."
                : "cli \"gemini\" (Google AI subscription, through Antigravity; the effort is part of the id, so pass none; no commands): \(ids.joined(separator: ", "))")
        } else {
            lines.append("cli \"gemini\": not installed.")
        }

        if let cursor = listing.cursor {
            let groks = cursorGroks(cursor)
            lines.append(groks.isEmpty
                ? "cli \"cursor\": installed, but it listed no Grok models. Sign in with: cursor-agent login"
                : "cli \"cursor\" (Grok models only; the effort is part of the id, so pass none): \(groks.joined(separator: ", "))")
        } else {
            lines.append("cli \"cursor\": not installed.")
        }
        return lines.joined(separator: "\n")
    }
}

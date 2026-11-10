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


    private static let longestListing = 80
    private static let listingTimeout: TimeInterval = 20

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
    static func modelLines(_ output: String) -> [String] {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = plain
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("Error") != true else { return [] }
        return Array(lines.prefix(longestListing))
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
            // Each line is "id<tab>Name"; the id is what the CLI takes.
            let ids = gemini
                .map { $0.components(separatedBy: "\t").first ?? $0 }
                .filter { $0.hasPrefix("gemini-") && !$0.contains(" ") }
            lines.append(ids.isEmpty
                ? "cli \"gemini\": installed, but it listed no Gemini models. Sign in by running agy once."
                : "cli \"gemini\" (Google AI subscription, through Antigravity; the effort is part of the id, so pass none; no commands): \(ids.joined(separator: ", "))")
        } else {
            lines.append("cli \"gemini\": not installed.")
        }

        if let cursor = listing.cursor {
            // Each line is "id - Name"; the id is what the CLI takes.
            let groks = cursor
                .map { $0.components(separatedBy: " - ").first ?? $0 }
                .filter { isGrok($0) && !$0.contains(" ") }
            lines.append(groks.isEmpty
                ? "cli \"cursor\": installed, but it listed no Grok models. Sign in with: cursor-agent login"
                : "cli \"cursor\" (Grok models only; the effort is part of the id, so pass none): \(groks.joined(separator: ", "))")
        } else {
            lines.append("cli \"cursor\": not installed.")
        }
        return lines.joined(separator: "\n")
    }
}

import Foundation

/// What a worker reported when it finished, whichever CLI it was.
public struct WorkerOutput: Codable, Equatable, Sendable {
    /// The worker's answer, or the reason it failed.
    public let text: String
    public let isError: Bool
    public let costUSD: Double
    /// Everything the model read, cached or not.
    public let inputTokens: Int
    /// Everything the model wrote, reasoning included.
    public let outputTokens: Int
    /// The CLI's own session id, which resumes this conversation in that CLI.
    public let sessionID: String?

    public init(
        text: String,
        isError: Bool,
        costUSD: Double = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        sessionID: String? = nil
    ) {
        self.text = text
        self.isError = isError
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.sessionID = sessionID
    }

    /// The same output, marked as a failure.
    func failed(fallbackText: String?) -> WorkerOutput {
        WorkerOutput(
            text: text.isEmpty ? (fallbackText ?? text) : text,
            isError: true,
            costUSD: costUSD,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            sessionID: sessionID
        )
    }

    /// The same output with another text and verdict: what the orchestrator
    /// makes of a run, as against what the CLI said.
    func replacing(text: String, isError: Bool) -> WorkerOutput {
        WorkerOutput(
            text: text,
            isError: isError,
            costUSD: costUSD,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            sessionID: sessionID
        )
    }

    /// Reads what `cli` printed on stdout in its JSON output mode.
    ///
    /// Output that is not the expected JSON — a shell error, a crash — is kept
    /// whole as an error rather than dropped: it is the only clue there is.
    public static func parse(_ stdout: String, cli: WorkerCLI) -> WorkerOutput {
        let parsed: WorkerOutput?
        switch cli {
        // cursor-agent's print mode answers in the shape claude's does.
        case .claude, .cursor: parsed = parseClaude(stdout)
        case .opencode: parsed = parseOpenCode(stdout)
        case .gemini: parsed = parseGemini(stdout)
        }
        if let parsed { return parsed }

        let raw = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkerOutput(text: raw.isEmpty ? "the agent printed nothing" : raw, isError: true)
    }

    /// `claude -p --output-format json` prints one object.
    private static func parseClaude(_ stdout: String) -> WorkerOutput? {
        guard let object = jsonObject(stdout), let text = object["result"] as? String else { return nil }
        let usage = object["usage"] as? [String: Any] ?? [:]
        // claude spells its usage in snake case; cursor, when it reports any,
        // in camel case. Each only ever has its own, so both are summed.
        let input = [
            "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
            "inputTokens", "cacheReadTokens", "cacheWriteTokens",
        ].reduce(0) { $0 + int(usage[$1]) }
        return WorkerOutput(
            text: text,
            isError: object["is_error"] as? Bool ?? false,
            costUSD: double(object["total_cost_usd"]),
            inputTokens: input,
            outputTokens: int(usage["output_tokens"]) + int(usage["outputTokens"]),
            sessionID: object["session_id"] as? String
        )
    }

    /// `agy --output-format json` prints one object: a status, the response,
    /// usage, and what it was refused for want of anyone to approve it.
    private static func parseGemini(_ stdout: String) -> WorkerOutput? {
        guard let object = jsonObject(stdout), let status = object["status"] as? String else { return nil }
        let usage = object["usage"] as? [String: Any] ?? [:]
        let refused = (object["denied_actions"] as? [[String: Any]] ?? [])
            .compactMap { ($0["display_name"] ?? $0["action"]) as? String }
        let refusal = refused.isEmpty ? nil : "refused without anyone to approve it: " + refused.joined(separator: ", ")
        let response = (object["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let text: String
        let isError: Bool
        if status != "SUCCESS" {
            text = (object["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "agy ended with status \(status)"
            isError = true
        } else if response.isEmpty {
            text = refusal ?? "the agent printed nothing"
            isError = true
        } else {
            text = refusal.map { response + "\n\n(" + $0 + ")" } ?? response
            isError = false
        }
        let id = object["conversation_id"] as? String
        return WorkerOutput(
            text: text,
            isError: isError,
            inputTokens: int(usage["input_tokens"]) + int(usage["cache_read_tokens"]),
            outputTokens: int(usage["output_tokens"]) + int(usage["thinking_tokens"]),
            sessionID: (id?.isEmpty ?? true) ? nil : id
        )
    }

    /// `opencode run --format json` prints one event per line.
    ///
    /// A run is a series of steps, each ending in tool calls or in a stop. What
    /// the model says before calling a tool is narration; the answer is what it
    /// says in the last step.
    private static func parseOpenCode(_ stdout: String) -> WorkerOutput? {
        var eventCount = 0
        var lastStepTexts: [String] = []
        var lastText: String?
        var failure: String?
        var cost = 0.0
        var input = 0
        var output = 0
        var sessionID: String?

        for line in stdout.split(separator: "\n") {
            guard let event = jsonObject(String(line)), let type = event["type"] as? String else { continue }
            eventCount += 1
            sessionID = sessionID ?? event["sessionID"] as? String
            let part = event["part"] as? [String: Any] ?? [:]

            switch type {
            case "step_start":
                lastStepTexts = []
            case "text":
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                lastStepTexts.append(text)
                lastText = text
            case "step_finish":
                let tokens = part["tokens"] as? [String: Any] ?? [:]
                let cache = tokens["cache"] as? [String: Any] ?? [:]
                cost += double(part["cost"])
                input += int(tokens["input"]) + int(cache["read"]) + int(cache["write"])
                output += int(tokens["output"]) + int(tokens["reasoning"])
            case "error":
                failure = errorMessage(event["error"])
            default:
                continue
            }
        }

        guard eventCount > 0 else { return nil }
        let answer = lastStepTexts.isEmpty ? (lastText ?? "") : lastStepTexts.joined(separator: "\n")
        return WorkerOutput(
            text: failure ?? answer,
            isError: failure != nil,
            costUSD: cost,
            inputTokens: input,
            outputTokens: output,
            sessionID: sessionID
        )
    }

    private static func errorMessage(_ error: Any?) -> String {
        let object = error as? [String: Any] ?? [:]
        let data = object["data"] as? [String: Any] ?? [:]
        return object["message"] as? String
            ?? data["message"] as? String
            ?? object["type"] as? String
            ?? "the agent reported an error"
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private static func double(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
}

/// A run that did not run because of its provider, not because of its work:
/// out of quota, signed out, or the API down. Nothing was delivered and
/// nothing is learned about the worker, so such a run counts for nobody.
public enum ProviderFailure: Codable, Equatable, Sendable {
    case quota(String)
    case signedOut(String)
    case unavailable(String)

    /// What kind it is, as it is said in reports.
    public var name: String {
        switch self {
        case .quota: return "quota"
        case .signedOut: return "signed out"
        case .unavailable: return "unavailable"
        }
    }

    /// The words that matched, as the provider wrote them.
    public var reason: String {
        switch self {
        case let .quota(reason), let .signedOut(reason), let .unavailable(reason): return reason
        }
    }

    /// How long the CLI stays out of the picker after this: nil until a later
    /// run of it succeeds, which is for a sign-in the user has to redo.
    public var stall: TimeInterval? {
        switch self {
        case .quota: return 60 * 60
        case .signedOut: return nil
        case .unavailable: return 10 * 60
        }
    }

    /// A provider's message is short; a worker's report of a failed task is
    /// not, and may mention a login or a quota for reasons of its own.
    static let longestMessage = 800

    private static let patterns: [(regex: String, make: @Sendable (String) -> ProviderFailure)] = [
        (#"free usage limit|usage limit|rate[ _-]?limit|quota|\b429\b|too many requests|\bcredit"#, { .quota($0) }),
        // A bare "login" is not enough: a worker that failed a task about
        // logins says it too. The CLIs ask to log in, they do not just name it.
        (
            #"authentication required|not (?:logged|signed) in|/login|unauthori[sz]ed|"#
                + #"\b(?:please|must|need to|run|try to)\b[^.\n]{0,20}\b(?:log|sign) ?in\b|"#
                + #"\b(?:log|sign) ?in (?:required|first|again)"#,
            { .signedOut($0) }
        ),
        (
            #"overloaded|service unavailable|bad gateway|gateway time-?out|"#
                + #"(?:http|status|error|code)[^0-9\n]{0,12}5\d\d\b|\b5\d\d (?:internal|server|service|bad|gateway)"#,
            { .unavailable($0) }
        ),
    ]

    /// Reads a failed run's answer and stderr for the provider's own words.
    /// Nil when neither is short enough to be the provider's.
    static func detect(text: String, errorTail: String?) -> ProviderFailure? {
        for source in [text, errorTail ?? ""] where source.count <= longestMessage {
            for (regex, make) in patterns {
                if let range = source.range(of: regex, options: [.regularExpression, .caseInsensitive]) {
                    return make(reason(of: source, around: range))
                }
            }
        }
        return nil
    }

    /// The line the match is in, trimmed and cut: what the provider said.
    private static func reason(of source: String, around range: Range<String.Index>) -> String {
        let text = source[source.lineRange(for: range)].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 160 ? String(text.prefix(159)) + "…" : text
    }
}

import Foundation

/// One turn of the maestro's own work: what it was asked, how long it took,
/// the tokens it moved and what they would cost at API prices.
struct MaestroTurn: Equatable {
    let id: String
    let prompt: String
    let started: Date
    var ended: Date
    var model: String?
    var input = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var output = 0
    /// The turn's last answer ended it (`end_turn`), not a tool call.
    var isDone = false

    var tokens: Int { input + cacheRead + cacheWrite5m + cacheWrite1h + output }

    /// Dollars at the model's API list price; zero for a model not listed.
    var cost: Double {
        guard let model, let price = MaestroPrice.of(model) else { return 0 }
        let perToken = 1 / 1_000_000.0
        return (Double(input) * price.input
            + Double(cacheRead) * price.cacheRead
            + Double(cacheWrite5m) * price.input * 1.25
            + Double(cacheWrite1h) * price.input * 2
            + Double(output) * price.output) * perToken
    }
}

/// API list prices, dollars per million tokens (2026-11).
enum MaestroPrice {
    struct Price { let input, output, cacheRead: Double }

    // ponytail: hand-kept table; a model not here shows $0.00 until added.
    static func of(_ model: String) -> Price? {
        let table: [(String, Price)] = [
            ("fable-5-2", Price(input: 8, output: 40, cacheRead: 0.20)),
            ("fable", Price(input: 10, output: 50, cacheRead: 1)),
            ("opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20)),
            ("opus", Price(input: 5, output: 25, cacheRead: 0.50)),
            ("sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.10)),
            ("sonnet", Price(input: 2, output: 10, cacheRead: 0.20)),
            ("haiku-5-5", Price(input: 0.10, output: 0.50, cacheRead: 0.01)),
            ("haiku", Price(input: 1, output: 5, cacheRead: 0.10)),
        ]
        return table.first { model.contains($0.0) }?.1
    }
}

/// Reads the maestro's conversation file into turns, a little at a time: the
/// file runs to tens of megabytes, so each refresh reads only what was added.
final class MaestroWorkLog {
    private(set) var turns: [MaestroTurn] = []
    /// Agents the maestro started, each read from its own file beside the
    /// conversation: one row each, running until claude marks it finished.
    private(set) var agents: [MaestroAgent] = []
    private var agentLogs: [String: MaestroWorkLog] = [:]
    /// Read a subagent's file, whose lines are all marked as a side chain.
    private var isSubagent = false
    private var url: URL?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var seen: Set<String> = []
    private var located: (session: String, url: URL?)?

    /// The conversation of `project`'s maestro: under the project's own
    /// folder, or under a worktree's when the maestro was started in one.
    func locate(_ project: CockpitProject) -> URL? {
        guard let session = TranscriptLocator.session(project: project) else { return nil }
        if let located, located.session == session { return located.url }
        let direct = TranscriptLocator.url(project: project.path, session: session)
        var found: URL? = FileManager.default.fileExists(atPath: direct.path) ? direct : nil
        if found == nil {
            let root = Maestro.conversationsDirectory
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            found = folders.map { $0.appendingPathComponent(session + ".jsonl") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        // ponytail: a session not written yet is looked for again only when it changes.
        located = (session, found)
        return found
    }

    /// Catches up with `url`; starts over when the file changed or shrank.
    func refresh(_ url: URL?) {
        if url != self.url { reset(url) }
        guard let url else { return }
        if !isSubagent { refreshAgents(beside: url) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { reset(url) }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        offset += UInt64(data.count)
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: 0x0A) else { return }
        let complete = pending[pending.startIndex ... lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        for line in complete.split(separator: 0x0A) { read(line) }
    }

    private func reset(_ url: URL?) {
        self.url = url
        offset = 0
        pending = Data()
        turns = []
        seen = []
        agents = []
        agentLogs = [:]
    }

    private func refreshAgents(beside conversation: URL) {
        let folder = conversation.deletingPathExtension().appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        agents = files.filter { $0.pathExtension == "jsonl" }.compactMap { file in
            let id = file.deletingPathExtension().lastPathComponent
            let log = agentLogs[id] ?? {
                let made = MaestroWorkLog()
                made.isSubagent = true
                agentLogs[id] = made
                return made
            }()
            log.refresh(file)
            let metaURL = file.deletingPathExtension().appendingPathExtension("meta.json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return MaestroAgent(id: id, description: meta?["description"] as? String, isFinished: meta?["finished"] as? Bool == true, turns: log.turns)
        }
    }

    func read(_ line: Data) {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              isSubagent || entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any],
              let time = (entry["timestamp"] as? String).flatMap(Self.date)
        else { return }
        switch entry["type"] as? String {
        case "user":
            guard entry["isMeta"] as? Bool != true, !(isSubagent && !turns.isEmpty),
                  let prompt = Self.prompt(message["content"]) else { return }
            turns.append(MaestroTurn(id: entry["uuid"] as? String ?? UUID().uuidString, prompt: prompt, started: time, ended: time))
        case "assistant":
            guard !turns.isEmpty else { return }
            var turn = turns.removeLast()
            defer { turns.append(turn) }
            turn.ended = time
            turn.model = message["model"] as? String ?? turn.model
            turn.isDone = message["stop_reason"] as? String == "end_turn"
            // claude writes one line per content block, each carrying the
            // message's usage: count a message once.
            guard let id = message["id"] as? String, seen.insert(id).inserted,
                  let usage = message["usage"] as? [String: Any] else { return }
            turn.input += usage["input_tokens"] as? Int ?? 0
            turn.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
            turn.output += usage["output_tokens"] as? Int ?? 0
            if let split = usage["cache_creation"] as? [String: Any] {
                turn.cacheWrite5m += split["ephemeral_5m_input_tokens"] as? Int ?? 0
                turn.cacheWrite1h += split["ephemeral_1h_input_tokens"] as? Int ?? 0
            } else {
                turn.cacheWrite5m += usage["cache_creation_input_tokens"] as? Int ?? 0
            }
        default:
            return
        }
    }

    /// What the user typed: plain text, not a tool's result, a slash
    /// command's echo or a notice the harness wrapped in tags.
    static func prompt(_ content: Any?) -> String? {
        let text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
        } else {
            text = nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted")
        else { return nil }
        return trimmed
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The agents as the work panel's rows: what the maestro handed off,
    /// running for as long as claude has not marked it finished.
    static func rows(_ agents: [MaestroAgent], now: Date, timeZone: TimeZone = .current) -> [(row: WorkerRow, started: Date)] {
        agents.compactMap { agent in
            guard let turn = agent.turn else { return nil }
            // A file that stopped growing long ago belongs to an agent that
            // went with its session, whatever its meta still says.
            let isRunning = !agent.isFinished && now.timeIntervalSince(turn.ended) < 600
            let model = turn.model.map { $0.replacingOccurrences(of: "claude-", with: "") } ?? "agente"
            let meta = [
                model,
                WorkerBoard.startedText(turn.started, now: now, timeZone: timeZone),
                WorkerBoard.duration((isRunning ? now : turn.ended).timeIntervalSince(turn.started)),
                WorkerBoard.money(turn.cost),
                WorkerBoard.tokens(turn.tokens),
            ].joined(separator: " · ")
            let title = agent.description ?? WorkerBoard.firstLine(turn.prompt)
            let row = WorkerRow(
                id: "agent-" + agent.id,
                title: WorkerBoard.shortened(title, to: 60),
                kind: isRunning ? .running : .done,
                stateText: isRunning ? "agente do maestro rodando" : "agente do maestro",
                meta: meta,
                detail: turn.prompt
            )
            return (row, turn.started)
        }
    }

    /// The turns as the work panel's rows. The last one runs while the
    /// maestro is in it; a turn cut off and never ended stops counting after
    /// a while.
    static func rows(_ turns: [MaestroTurn], now: Date, timeZone: TimeZone = .current) -> [(row: WorkerRow, started: Date)] {
        turns.enumerated().map { index, turn in
            let isRunning = index == turns.count - 1 && !turn.isDone && now.timeIntervalSince(turn.ended) < 600
            let model = turn.model.map { $0.replacingOccurrences(of: "claude-", with: "") } ?? "maestro"
            let meta = [
                model,
                WorkerBoard.startedText(turn.started, now: now, timeZone: timeZone),
                WorkerBoard.duration((isRunning ? now : turn.ended).timeIntervalSince(turn.started)),
                WorkerBoard.money(turn.cost),
                WorkerBoard.tokens(turn.tokens),
            ].joined(separator: " · ")
            let row = WorkerRow(
                id: "maestro-" + turn.id,
                title: WorkerBoard.shortened(WorkerBoard.firstLine(turn.prompt), to: 60),
                kind: isRunning ? .running : .done,
                stateText: isRunning ? "maestro trabalhando" : "maestro",
                meta: meta,
                detail: turn.prompt
            )
            return (row, turn.started)
        }
    }
}

/// An agent the maestro started inside its own session (claude's Agent tool).
struct MaestroAgent: Equatable {
    let id: String
    let description: String?
    let isFinished: Bool
    let turns: [MaestroTurn]

    /// The agent's whole run as one turn: its brief, first to last line, every token.
    var turn: MaestroTurn? {
        guard var total = turns.first else { return nil }
        for more in turns.dropFirst() {
            total.ended = more.ended
            total.model = more.model ?? total.model
            total.input += more.input
            total.cacheRead += more.cacheRead
            total.cacheWrite5m += more.cacheWrite5m
            total.cacheWrite1h += more.cacheWrite1h
            total.output += more.output
        }
        return total
    }
}

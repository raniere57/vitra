import Foundation

/// Hands Vitra's browser to the worker CLIs that find their MCP servers in a
/// settings file of their own: cursor, and agy, which runs the gemini
/// workers. (claude is given the server on its command line, and opencode
/// already has it.)
enum WorkerBrowser {
    /// `existing` with Vitra's server in its `mcpServers`, or nil when there
    /// is nothing to write: it is there already, or the file is not plain
    /// JSON, which is the user's to sort out and not ours to overwrite.
    static func merged(binary: String, trust: Bool, extra: [String: Any] = [:], into existing: Data?) -> Data? {
        var object: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            // A file that names `mcpServers` twice is read differently by
            // different parsers — one keeps the first block, another the last
            // — and rewriting it from what this one saw would drop servers
            // the CLI was using. It is left exactly as it is.
            let text = String(decoding: existing, as: UTF8.self)
            guard text.components(separatedBy: "\"mcpServers\"").count <= 2 else { return nil }
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return nil }
            object = parsed
        }
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": binary, "args": ["mcp"]]
        // gemini asks before each tool of a server it does not trust, and a
        // headless worker has nobody to answer.
        if trust { entry["trust"] = true }
        entry.merge(extra) { _, new in new }
        if let current = servers["vitra"] as? NSDictionary, current.isEqual(to: entry) { return nil }
        servers["vitra"] = entry
        object["mcpServers"] = servers
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The rule that lets agy call Vitra's tools with nobody to approve them:
    /// headless, a tool that needs approval is refused. Only Vitra's server,
    /// which serves a worker only what a worker may use.
    static let agyRule = "mcp(vitra/*)"

    /// `existing` agy settings with Vitra's tools allowed, or nil when there
    /// is nothing to write or the file is not ours to rewrite.
    static func allowingVitra(in existing: Data?) -> Data? {
        var object: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return nil }
            object = parsed
        }
        var permissions = object["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        guard !allow.contains(agyRule) else { return nil }
        allow.append(agyRule)
        permissions["allow"] = allow
        object["permissions"] = permissions
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Adds the server to cursor's and agy's settings, and lets agy use it.
    /// Best effort: a worker without the browser still does everything else.
    static func register(binary: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        for path in [".cursor/mcp.json", ".gemini/config/mcp_config.json"] {
            let file = home.appendingPathComponent(path)
            let existing = try? Data(contentsOf: file)
            // agy writes "disabled": false beside each server it knows.
            let extra: [String: Any] = path.contains("mcp_config") ? ["disabled": false] : [:]
            guard let data = merged(binary: binary, trust: false, extra: extra, into: existing) else { continue }
            write(data, to: file, replacing: existing)
        }
        let settings = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        let existing = try? Data(contentsOf: settings)
        if let data = allowingVitra(in: existing) { write(data, to: settings, replacing: existing) }
    }

    private static func write(_ data: Data, to file: URL, replacing existing: Data?) {
        do {
            // What was there is kept beside it the first time, untouched.
            let backup = file.appendingPathExtension("antes-do-vitra")
            if let existing, !existing.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
                try existing.write(to: backup)
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // ponytail: silent on purpose; a worker without the browser still works.
        }
    }
}

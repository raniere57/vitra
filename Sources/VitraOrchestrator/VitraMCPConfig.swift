import Foundation

/// The MCP configurations that give a CLI Vitra's tools, and the environment
/// each one hands the helper that serves them.
///
/// The helper picks its tool set from its own environment, and a CLI may start
/// it with a clean one. So the environment rides in the configuration itself:
/// a worker's configuration names that worker, and the maestro's names its
/// role. Anything that arrives without a configuration gets the worker's set.
public enum VitraMCPConfig {
    /// Names which tool set the helper serves.
    public static let roleKey = "VITRA_ROLE"
    /// The only role that gets the maestro's tool set.
    public static let maestroRole = "maestro"

    /// The worker's run id, its run directory, and the project it works in.
    public static let agentKey = "VITRA_AGENT"
    public static let runKey = "VITRA_RUN"
    public static let projectKey = "VITRA_PROJECT"

    /// The environment of the maestro's helper.
    public static func maestroEnvironment() -> [String: String] {
        [roleKey: maestroRole]
    }

    /// The identity of a worker run. The project is left out when there is none.
    public static func workerEnvironment(id: String, run: URL, project: String?) -> [String: String] {
        var environment = [agentKey: id, runKey: run.path]
        if let project, !project.isEmpty { environment[projectKey] = project }
        return environment
    }

    /// A Claude `--mcp-config` file starting the helper with `environment`.
    public static func claudeConfig(binary: String, environment: [String: String]) -> String {
        json(["mcpServers": ["vitra": ["command": binary, "args": ["mcp"], "env": environment]]])
    }

    /// An `OPENCODE_CONFIG` file: opencode merges it over the user's own
    /// configuration, so their settings stay as they are.
    public static func opencodeConfig(binary: String, environment: [String: String]) -> String {
        json([
            "$schema": "https://opencode.ai/config.json",
            "mcp": [
                "vitra": [
                    "type": "local",
                    "command": [binary, "mcp"],
                    "environment": environment,
                    "enabled": true,
                ],
            ],
        ])
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

import Darwin
import Foundation

/// Who the helper serves: the worker run it belongs to, the project, and the pane.
///
/// A CLI may start its MCP servers with a clean environment, so the variables
/// its parent set are not always in the helper's own. Then the helper walks up
/// to the nearest ancestor that carries them. That is the worker's wrapper
/// shell, which the orchestrator started with the variables set.
struct AgentIdentity: Equatable, Sendable {
    /// The worker's run id, or nil for the maestro.
    let agent: String?
    /// The project path, from the environment or the worker's `run.json`.
    let project: String?
    /// The pane the helper was started from.
    let pane: String?

    /// Resolved once per helper process, the first time anything asks.
    static let current = resolve(own: ProcessInfo.processInfo.environment, startingAt: getpid())

    /// Keys the parent sets. `VITRA_RUN` is the run directory; its last path
    /// component is the run id.
    static let agentKey = "VITRA_AGENT"
    static let runKey = "VITRA_RUN"
    static let projectKey = "VITRA_PROJECT"
    static let paneKey = "VITRA_PANE"

    /// How many parents to climb before giving up. A worker's wrapper is a few
    /// steps up; anything deeper is not one of ours.
    static let maxAncestorSteps = 32

    /// Resolves the identity of a process whose own environment is `own` and
    /// whose ancestors start at `pid`'s parent.
    static func resolve(own: [String: String], startingAt pid: pid_t) -> AgentIdentity {
        resolve(
            own: own,
            nearestAncestor: { nearestAncestorEnvironment(of: pid) },
            runProject: { runDirectory in
                projectFromRunRecord(at: URL(fileURLWithPath: runDirectory).appendingPathComponent("run.json"))
            }
        )
    }

    /// The precedence, with the lookups injected so each rule is testable.
    ///
    /// The source is the helper's own environment when it names a worker or a
    /// run; otherwise the nearest ancestor that does. Each field is taken from
    /// the helper's own environment first, then from the source, and the
    /// project finally from the run record.
    static func resolve(
        own: [String: String],
        nearestAncestor: () -> [String: String]?,
        runProject: (String) -> String?
    ) -> AgentIdentity {
        let ownNamesWorker = own.nonEmpty(agentKey) != nil || own.nonEmpty(runKey) != nil
        let source = ownNamesWorker ? own : (nearestAncestor() ?? [:])

        let agent = source.nonEmpty(agentKey)
            ?? source.nonEmpty(runKey).map { URL(fileURLWithPath: $0).lastPathComponent }
        let project = own.nonEmpty(projectKey)
            ?? source.nonEmpty(projectKey)
            ?? source.nonEmpty(runKey).flatMap(runProject)
        let pane = own.nonEmpty(paneKey) ?? source.nonEmpty(paneKey)
        return AgentIdentity(agent: agent, project: project, pane: pane)
    }

    /// The environment of the nearest ancestor that sets `VITRA_RUN` or
    /// `VITRA_AGENT`, or nil if none does before pid 1.
    static func nearestAncestorEnvironment(of pid: pid_t) -> [String: String]? {
        var child = pid
        for _ in 0..<maxAncestorSteps {
            guard let parent = parentProcessID(of: child), parent > 1 else { return nil }
            if let environment = environment(ofProcess: parent),
               environment.nonEmpty(agentKey) != nil || environment.nonEmpty(runKey) != nil {
                return environment
            }
            child = parent
        }
        return nil
    }

    // MARK: - Reading other processes (same user only; the kernel refuses the rest)

    /// The environment a process started with, read from its KERN_PROCARGS2.
    static func environment(ofProcess pid: pid_t) -> [String: String]? {
        procargs2(ofProcess: pid).flatMap(environment(procargs2:))
    }

    static func procargs2(ofProcess pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Data(buffer.prefix(size))
    }

    /// The parent of a process, from its kinfo_proc.
    static func parentProcessID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }

    /// Parses a KERN_PROCARGS2 buffer: argc as an Int32 in native byte order,
    /// the exec path, NUL padding, then argc argv strings and the environment
    /// strings (`KEY=value`), each NUL-terminated.
    ///
    /// Pure, so a hand-made buffer can test it. Returns nil when the buffer is
    /// too short to hold the argv it claims. The first occurrence of a key wins.
    static func environment(procargs2 data: Data) -> [String: String]? {
        guard data.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = data.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var cursor = data.startIndex + MemoryLayout<Int32>.size

        // The exec path, then the padding the kernel puts before argv[0].
        guard let execEnd = data[cursor...].firstIndex(of: 0) else { return nil }
        cursor = execEnd
        while cursor < data.endIndex, data[cursor] == 0 { cursor += 1 }

        // argv is counted, empty strings included, so it can be skipped exactly.
        for _ in 0..<max(Int(argc), 0) {
            guard let end = data[cursor...].firstIndex(of: 0) else { return nil }
            cursor = end + 1
        }

        // The rest is the environment. Empty strings are the trailing padding.
        var environment: [String: String] = [:]
        while cursor < data.endIndex {
            let start = cursor
            let end = data[cursor...].firstIndex(of: 0) ?? data.endIndex
            cursor = end + 1
            guard let equals = data[start..<end].firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: data[start..<equals], as: UTF8.self)
            let value = String(decoding: data[(equals + 1)..<end], as: UTF8.self)
            if environment[key] == nil { environment[key] = value }
        }
        return environment
    }

    /// The `spec.project` of a worker's `run.json`, or nil if it is missing or unreadable.
    static func projectFromRunRecord(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return projectFromRunRecord(data)
    }

    /// Pure version of `projectFromRunRecord(at:)` for tests.
    static func projectFromRunRecord(_ data: Data) -> String? {
        struct Record: Decodable {
            struct Spec: Decodable { let project: String? }
            let spec: Spec
        }
        return (try? JSONDecoder().decode(Record.self, from: data))?.spec.project.flatMap { $0.isEmpty ? nil : $0 }
    }
}

private extension Dictionary where Key == String, Value == String {
    /// The value for `key`, or nil when it is absent or empty.
    func nonEmpty(_ key: String) -> String? {
        self[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}

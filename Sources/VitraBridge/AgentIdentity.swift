import Darwin
import Foundation
import VitraOrchestrator

/// Who the helper serves: the worker run it belongs to, the project, and the pane.
///
/// Three sources, in order. The helper's own environment, which a worker's own
/// MCP configuration sets. Then the working directory, for an editing worker
/// whose tree sits inside its run directory. Then the nearest ancestor whose
/// environment carries the variables: the worker's wrapper shell, for a CLI
/// that started the helper with a clean environment.
struct AgentIdentity: Equatable, Sendable {
    /// The worker's run id, or nil for the maestro.
    let agent: String?
    /// The project path, from the environment or the worker's `run.json`.
    let project: String?
    /// The pane the helper was started from.
    let pane: String?

    /// Resolved once per helper process, the first time anything asks.
    static let current = resolve(
        own: ProcessInfo.processInfo.environment,
        cwd: FileManager.default.currentDirectoryPath,
        startingAt: getpid()
    )

    /// Keys the parent sets. `VITRA_RUN` is the run directory; its last path
    /// component is the run id.
    static let agentKey = VitraMCPConfig.agentKey
    static let runKey = VitraMCPConfig.runKey
    static let projectKey = VitraMCPConfig.projectKey
    static let paneKey = "VITRA_PANE"

    /// How many parents to climb before giving up. A worker's wrapper is a few
    /// steps up; anything deeper is not one of ours.
    static let maxAncestorSteps = 32

    /// Resolves the identity of a process whose own environment is `own`, whose
    /// working directory is `cwd`, and whose ancestors start at `pid`'s parent.
    static func resolve(own: [String: String], cwd: String? = nil, startingAt pid: pid_t) -> AgentIdentity {
        resolve(
            own: own,
            cwd: cwd,
            nearestAncestor: { nearestAncestorEnvironment(of: pid) },
            runProject: { runDirectory in
                projectFromRunRecord(at: URL(fileURLWithPath: runDirectory).appendingPathComponent("run.json"))
            }
        )
    }

    /// The precedence, with the lookups injected so each rule is testable.
    ///
    /// When the helper's own environment names a worker or a run, that is the
    /// source. Failing that, a working directory inside a run's directory names
    /// the run. Failing that, the nearest ancestor that names one is the source.
    /// Each field is taken from the helper's own environment first, then from
    /// the source, and the project finally from the run record.
    static func resolve(
        own: [String: String],
        cwd: String? = nil,
        runsRoot: URL = Orchestrator.defaultRoot,
        nearestAncestor: () -> [String: String]?,
        runProject: (String) -> String?
    ) -> AgentIdentity {
        let ownNamesWorker = own.nonEmpty(agentKey) != nil || own.nonEmpty(runKey) != nil
        if !ownNamesWorker, let run = runDirectory(containing: cwd, under: runsRoot) {
            return AgentIdentity(
                agent: run.lastPathComponent,
                project: own.nonEmpty(projectKey) ?? runProject(run.path),
                pane: own.nonEmpty(paneKey)
            )
        }
        let source = ownNamesWorker ? own : (nearestAncestor() ?? [:])

        let agent = source.nonEmpty(agentKey)
            ?? source.nonEmpty(runKey).map { URL(fileURLWithPath: $0).lastPathComponent }
        let project = own.nonEmpty(projectKey)
            ?? source.nonEmpty(projectKey)
            ?? source.nonEmpty(runKey).flatMap(runProject)
        let pane = own.nonEmpty(paneKey) ?? source.nonEmpty(paneKey)
        return AgentIdentity(agent: agent, project: project, pane: pane)
    }

    /// The run directory `cwd` sits in, when it is inside `runsRoot`: the first
    /// path component below the root is the run id. Both sides are resolved
    /// through symlinks, so `/var` and `/private/var` compare equal.
    static func runDirectory(containing cwd: String?, under runsRoot: URL) -> URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let root = runsRoot.resolvingSymlinksInPath().standardizedFileURL
        let here = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = root.pathComponents
        guard here.count > base.count, Array(here.prefix(base.count)) == base else { return nil }
        let id = here[base.count]
        guard !id.isEmpty, id != "/" else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    /// Which tool set the helper serves. The maestro's when its own environment
    /// names no worker or run and either says it is the maestro or carries
    /// `VITRA_PANE`. The pane is set in the project's shell, so a maestro started
    /// from a config written before the role existed, or relaunched by hand,
    /// still gets its tools. Everything else gets the worker's set: a worker
    /// whose variables were dropped, or a caller that is not known at all.
    ///
    /// A maestro in solo mode says `VITRA_ROLE=solo` and gets the panel and
    /// memory tools without the agent ones; it carries `VITRA_PANE` too, so
    /// the role is read before the pane.
    enum ServedRole: Equatable, Sendable {
        case maestro
        case solo
        case worker

        /// `ancestor` is the nearest ancestor's environment that names a run,
        /// a worker or a role: a CLI that starts the helper with a clean
        /// environment, as Cursor does, still has its own to be read. A run or
        /// a worker named there is a worker, whatever else it says.
        static func decide(own: [String: String], ancestor: () -> [String: String]?) -> ServedRole {
            if own.nonEmpty(agentKey) != nil || own.nonEmpty(runKey) != nil || own[VitraMCPConfig.roleKey] != nil
                || own.nonEmpty(paneKey) != nil {
                return decide(own: own)
            }
            guard let above = ancestor(), above[VitraMCPConfig.roleKey] != nil else { return .worker }
            return decide(own: above)
        }

        static func decide(own: [String: String]) -> ServedRole {
            let names = own.nonEmpty(agentKey) != nil || own.nonEmpty(runKey) != nil
            if own[VitraMCPConfig.roleKey] == StdioBridge.soloRole { return names ? .worker : .solo }
            let saysMaestro = own[VitraMCPConfig.roleKey] == VitraMCPConfig.maestroRole
                || own.nonEmpty(paneKey) != nil
            return saysMaestro && !names ? .maestro : .worker
        }
    }

    /// The environment of the nearest ancestor that sets `VITRA_RUN` or
    /// `VITRA_AGENT`, or nil if none does before pid 1.
    static func nearestAncestorEnvironment(of pid: pid_t) -> [String: String]? {
        var child = pid
        for _ in 0..<maxAncestorSteps {
            guard let parent = parentProcessID(of: child), parent > 1 else { return nil }
            if let environment = environment(ofProcess: parent),
               environment.nonEmpty(agentKey) != nil || environment.nonEmpty(runKey) != nil
                || environment.nonEmpty(VitraMCPConfig.roleKey) != nil {
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

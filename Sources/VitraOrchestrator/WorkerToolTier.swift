import Foundation

/// How much of Vitra's own tools a worker may reach, decided from its spec.
///
/// A worker reads whatever it is pointed at, and what it reads can carry a
/// prompt injection: a diff, a web page, a README. So what a worker may do
/// with Vitra is decided by what the maestro spawned it for — never by
/// anything the worker says — and is no more than that job needs:
///
/// - `auditor`: an automatic audit, or any read-only review. It reads a diff
///   another model wrote, often with a third party's model, and needs nothing
///   of Vitra's but the project's notes: it reads the checkout with its own
///   CLI's tools. No browser, no screen, no shared terminal, no panel.
/// - `reader`: any other read-only worker. It may open and look at pages in
///   its own browser tab and keep the notes, but not drive a page (click,
///   type, run JavaScript), look at the screen or the shared terminal.
/// - `editor`: a worker that edits. Everything a worker had before, but the
///   browser only in its own tab and the screen only one named app's window.
///
/// The maestro and a solo maestro are not workers and have no tier.
public enum WorkerToolTier: String, Sendable, CaseIterable {
    case auditor
    case reader
    case editor

    /// The tier a run with `spec` works in. No spec — an unknown or missing
    /// run — is the most restricted: whoever claims to be a worker and cannot
    /// be found is given the least.
    public init(spec: WorkerSpec?) {
        guard let spec else { self = .auditor; return }
        switch spec.access {
        case .edit: self = .editor
        case .read: self = Self.audits(spec) ? .auditor : .reader
        }
    }

    /// Whether a read-only spec is an audit: the automatic one (its focuses,
    /// or the label the audit is spawned with) or a review the maestro asked
    /// for. Both read work somebody else's model wrote.
    private static func audits(_ spec: WorkerSpec) -> Bool {
        spec.isAudit || spec.kind == .review || spec.label?.hasPrefix(auditLabelPrefix) == true
    }

    /// The start of the label an automatic audit is spawned with.
    public static let auditLabelPrefix = "auditoria:"

    /// The tier of the run `id` under `root`, read from its record on disk.
    ///
    /// The id comes from the caller, so anything that is not exactly the shape
    /// a spawn hands out is refused before it becomes a path; that, a missing
    /// record and an unreadable one are all the most restricted tier.
    public static func of(run id: String?, root: URL = Orchestrator.defaultRoot) -> WorkerToolTier {
        guard let id, Orchestrator.isRunID(id),
              let data = try? Data(contentsOf: root.appendingPathComponent(id).appendingPathComponent("run.json")),
              let record = try? JSONDecoder().decode(RunRecord.self, from: data)
        else { return .auditor }
        return WorkerToolTier(spec: record.spec)
    }

    /// The tools of Vitra's this tier is served, by name.
    public var tools: Set<String> {
        switch self {
        case .auditor: Self.auditorTools
        case .reader: Self.readerTools
        case .editor: Self.editorTools
        }
    }

    private static let auditorTools: Set<String> = ["memory_read"]
    private static let readerTools: Set<String> = [
        "browser_open", "browser_snapshot", "browser_screenshot", "browser_console",
        "browser_back", "browser_forward", "browser_tabs", "memory_read", "memory_add",
    ]
    private static let editorTools: Set<String> = readerTools.union([
        "browser_click", "browser_type", "browser_eval", "preview_file", "screen_capture", "terminal_read",
    ])

    /// Why `tool` is not this tier's, in a few words, or nil when it is.
    public func refusal(of tool: String) -> String? {
        guard !tools.contains(tool) else { return nil }
        switch self {
        case .auditor:
            return "an auditor reads the checkout with its own tools; of Vitra's it has only memory_read"
        case .reader:
            return "a read-only worker may open and look at pages in its own tab and keep notes, not \(tool)"
        case .editor:
            return "\(tool) is the maestro's"
        }
    }

    /// The line the worker's prompt starts with, so it does not spend turns
    /// on tools it will not be given. Nil for an editor, which has them all.
    public var promptLine: String? {
        switch self {
        case .auditor:
            return "Of Vitra's tools you have only memory_read: read the code with your own tools."
        case .reader:
            return "Of Vitra's tools you have browser_open, browser_snapshot, browser_screenshot, browser_console, browser_back, browser_forward and browser_tabs (your own tab only), memory_read and memory_add."
        case .editor:
            return nil
        }
    }
}

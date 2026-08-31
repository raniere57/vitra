import AppKit
import VitraBridge
import VitraCore
import VitraPanel

/// Runs MCP tool calls against the live window.
///
/// Everything here touches AppKit, so the whole type is main-actor isolated and
/// the socket's handler hops onto it. No tool runs a shell command, and the only
/// file a tool reads is the one it was asked to show.
@MainActor
final class ToolRunner {
    /// Screenshots are kept apart from attachments: they are the agent's
    /// working notes, not something the user chose to attach.
    private let screenshots = AttachmentStore(
        directory: Vitra.supportDirectory.appendingPathComponent("screenshots", isDirectory: true)
    )

    private unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
    }

    func run(tool: String, arguments: JSONValue) async throws -> String {
        do {
            return try await dispatch(tool: tool, arguments: arguments)
        } catch let failure as ToolFailure {
            // The panel reports failures in its own type, which knows nothing
            // about MCP; this is where they become something the agent reads.
            throw ToolError(failure.message)
        }
    }

    private func dispatch(tool: String, arguments: JSONValue) async throws -> String {
        switch tool {
        case "preview_file": return try previewFile(arguments)
        case "browser_open": return try await browserOpen(arguments)
        case "browser_snapshot": return try await browser().snapshot()
        case "browser_click": return try await browserClick(arguments)
        case "browser_type": return try await browserType(arguments)
        case "browser_eval": return try await browserEval(arguments)
        case "browser_screenshot": return try await browserScreenshot()
        case "browser_console": return try browserConsole(arguments)
        default: throw ToolError("unknown tool: \(tool)")
        }
    }

    // MARK: - Tools

    private func previewFile(_ arguments: JSONValue) throws -> String {
        guard let path = arguments["path"]?.stringValue else { throw ToolError("path is required") }
        guard let target = PreviewTarget.resolve(path: path) else {
            throw ToolError("not a readable file: \(path)")
        }
        try window().preview(target)
        return "showing \(target.displayName) in Vitra's panel"
    }

    private func browserOpen(_ arguments: JSONValue) async throws -> String {
        guard let text = arguments["url"]?.stringValue else { throw ToolError("url is required") }
        guard let url = BrowserView.url(from: text) else { throw ToolError("not a URL: \(text)") }

        let browser = try browser()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            browser.load(url) { result in
                continuation.resume(with: result.mapError { ToolError($0.localizedDescription) })
            }
        }

        let title = browser.currentTitle
        let final = browser.currentURL?.absoluteString ?? url.absoluteString
        return title.isEmpty ? "opened \(final)" : "opened \(final)\ntitle: \(title)"
    }

    private func browserClick(_ arguments: JSONValue) async throws -> String {
        guard let ref = arguments["ref"]?.stringValue else { throw ToolError("ref is required") }
        return try await browser().click(ref: ref)
    }

    private func browserType(_ arguments: JSONValue) async throws -> String {
        guard let ref = arguments["ref"]?.stringValue else { throw ToolError("ref is required") }
        guard let text = arguments["text"]?.stringValue else { throw ToolError("text is required") }
        let submit = arguments["submit"]?.boolValue ?? false
        return try await browser().type(ref: ref, text: text, submit: submit)
    }

    private func browserEval(_ arguments: JSONValue) async throws -> String {
        guard let script = arguments["script"]?.stringValue else { throw ToolError("script is required") }
        let value = try await browser().evaluateUserScript(script)
        return Self.describe(value)
    }

    private func browserScreenshot() async throws -> String {
        let url = try await browser().screenshot(into: screenshots)
        return url.path
    }

    private func browserConsole(_ arguments: JSONValue) throws -> String {
        let browser = try browser()
        let messages = browser.console
        if arguments["clear"]?.boolValue == true { browser.clearConsole() }
        return messages.isEmpty ? "(no console output)" : messages.joined(separator: "\n")
    }

    // MARK: - Context

    private func window() throws -> TerminalWindowController {
        guard let controller = app.frontController else {
            throw ToolError("Vitra has no window open")
        }
        return controller
    }

    private func browser() throws -> BrowserView {
        try window().browser()
    }

    /// Renders a JavaScript result the way an agent can read it.
    private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "undefined" }
        if let text = value as? String { return text }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }
}

/// The socket's view of the runner: a plain executor that hops to the main actor.
struct GUIToolExecutor: ToolExecutor {
    let runner: ToolRunner

    func run(tool: String, arguments: JSONValue) async throws -> String {
        try await runner.run(tool: tool, arguments: arguments)
    }
}

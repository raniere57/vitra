import AppKit
import VitraBridge
import VitraCore
import VitraPanel

/// Where a tool call lands: whoever owns the windows.
///
/// The classic app and the cockpit lay their windows out differently, and a
/// tool should not have to know which one it is running in. It asks for a
/// place to show a file or a browser to drive, naming the pane the call came
/// from, and the host finds the right one.
protocol ToolHost: AnyObject {
    /// Shows `target` in the panel beside the pane named, bringing it forward.
    @MainActor func preview(_ target: PreviewTarget, pane: String?) throws
    /// The calling agent's own browser tab beside the pane named, opened if
    /// it was closed. `agent` is the worker's run, or nil for the maestro.
    @MainActor func browser(pane: String?, agent: String?) throws -> BrowserView
    /// Another agent's tab, to look at and not to drive.
    @MainActor func browser(pane: String?, tab: String) throws -> BrowserView
    /// The browser's tabs, one line each, saying which is the caller's.
    @MainActor func browserTabs(pane: String?, agent: String?) throws -> [String]
    /// The shell the project's user and agents share, started if it was not.
    /// `showing` brings its tab forward, for a command about to be typed.
    @MainActor func sharedTerminal(pane: String?, showing: Bool) throws -> TerminalSession
}

extension ToolHost {
    // A host with one browser per pane has no other tabs to look at.
    @MainActor func browser(pane: String?, tab: String) throws -> BrowserView {
        throw ToolError("there is no tab '\(tab)' here")
    }

    @MainActor func browserTabs(pane: String?, agent: String?) throws -> [String] { [] }

    @MainActor func sharedTerminal(pane: String?, showing: Bool) throws -> TerminalSession {
        throw ToolError("there is no shared terminal here")
    }
}

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

    private unowned let host: any ToolHost

    init(host: any ToolHost) {
        self.host = host
    }

    /// The pane the call in flight came from, for the window and browser it
    /// should land in. One call at a time on the main actor, so a property.
    private var callingPane: String?
    /// The worker the call came from; nil for the maestro. The helper puts it
    /// in the arguments from its own environment, never from the model.
    private var callingAgent: String?

    func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String {
        callingPane = pane
        callingAgent = arguments["_agent"]?.stringValue
        defer { (callingPane, callingAgent) = (nil, nil) }
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
        case "browser_snapshot": return try await looking(arguments).snapshot()
        case "terminal_read": return try terminalRead(arguments)
        case "terminal_run": return try await terminalRun(arguments)
        case "browser_tabs":
            let tabs = try host.browserTabs(pane: callingPane, agent: callingAgent)
            return tabs.isEmpty ? "(no tabs open)" : tabs.joined(separator: "\n")
        case "browser_click": return try await browserClick(arguments)
        case "browser_type": return try await browserType(arguments)
        case "browser_back": return try await browser().back()
        case "browser_forward": return try await browser().forward()
        case "browser_eval": return try await browserEval(arguments)
        case "browser_screenshot": return try await looking(arguments).screenshot(into: screenshots).path
        case "browser_console": return try browserConsole(arguments)
        case "screen_capture": return try await screenCapture(arguments)
        default: throw ToolError("unknown tool: \(tool)")
        }
    }

    // MARK: - Tools

    private func previewFile(_ arguments: JSONValue) throws -> String {
        guard let path = arguments["path"]?.stringValue else { throw ToolError("path is required") }
        guard let target = PreviewTarget.resolve(path: path) else {
            throw ToolError("not a readable file: \(path)")
        }
        try host.preview(target, pane: callingPane)
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

    private func browserConsole(_ arguments: JSONValue) throws -> String {
        let browser = try looking(arguments)
        let messages = browser.console
        // Emptying the buffer changes the tab: only its owner does that.
        if arguments["clear"]?.boolValue == true, otherTab(arguments) == nil { browser.clearConsole() }
        return messages.isEmpty ? "(no console output)" : messages.joined(separator: "\n")
    }

    /// A picture of what is on the user's screen: the window of the app named,
    /// or the whole display when no app is named.
    private func screenCapture(_ arguments: JSONValue) async throws -> String {
        let png = try await ScreenCapture.png(app: arguments["app"]?.stringValue)
        return try screenshots.store(png, extension: "png", prefix: "screen").path
    }

    // MARK: - The shared terminal

    private func terminalRead(_ arguments: JSONValue) throws -> String {
        let session = try host.sharedTerminal(pane: callingPane, showing: false)
        let lines = arguments["lines"]?.intValue ?? SharedTerminalText.defaultLines
        let text = SharedTerminalText.tail(session.screenText(), lines: lines)
        return text.isEmpty ? "(the terminal is empty)" : text
    }

    private func terminalRun(_ arguments: JSONValue) async throws -> String {
        // A worker is held to the commands the maestro allowed it; typing
        // into a shell everyone shares would be a way round that.
        guard callingAgent == nil else {
            throw ToolError("only the maestro and the user type in the shared terminal. Run the commands you were given in your own shell, or report what should be run.")
        }
        let command = (arguments["command"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = SharedTerminalText.problem(with: command) { throw ToolError(problem) }

        let session = try host.sharedTerminal(pane: callingPane, showing: true)
        guard !session.isRunningProgram else {
            throw ToolError("the terminal is busy running \(session.foregroundName ?? "a program"). Wait for it, or ask the user.")
        }
        // A shell that was started for this call is still reading its
        // profile: what is typed before its first prompt is shown is thrown
        // away by some setups and run out of order by others.
        await shellReady(session)
        let before = session.screenText()
        session.send(text: command + "\n")

        // Done when nothing is running and the screen has held still: a
        // builtin such as cd never shows as a running program at all.
        let limit = TimeInterval(min(max(arguments["timeout_seconds"]?.intValue ?? 60, 1), 600))
        let began = Date()
        var last = before
        var still = 0
        while Date().timeIntervalSince(began) < limit {
            try? await Task.sleep(for: .milliseconds(150))
            let now = session.screenText()
            still = (now == last && now != before && !session.isRunningProgram) ? still + 1 : 0
            last = now
            if still >= 3 { return SharedTerminalText.added(before: before, after: now) }
        }
        let note = session.isRunningProgram
            ? "\n(still running after \(Int(limit))s; terminal_read shows more)"
            : ""
        return SharedTerminalText.added(before: before, after: session.screenText()) + note
    }

    /// Waits for the shell's prompt: something on screen that has held still.
    private func shellReady(_ session: TerminalSession) async {
        let deadline = Date().addingTimeInterval(10)
        var last = session.screenText()
        var still = 0
        while Date() < deadline, still < 4 {
            try? await Task.sleep(for: .milliseconds(150))
            let now = session.screenText()
            still = (now == last && !now.isEmpty) ? still + 1 : 0
            last = now
        }
    }

    // MARK: - Context

    private func browser() throws -> BrowserView {
        try host.browser(pane: callingPane, agent: callingAgent)
    }

    private func otherTab(_ arguments: JSONValue) -> String? {
        arguments["tab"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The tab a tool that only looks should look at: the one named, which
    /// may be anybody's, or the caller's own.
    private func looking(_ arguments: JSONValue) throws -> BrowserView {
        guard let tab = otherTab(arguments) else { return try browser() }
        return try host.browser(pane: callingPane, tab: tab)
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

extension AppDelegate: ToolHost {
    @MainActor private func toolWindow(pane: String?) throws -> TerminalWindowController {
        // The agent's own window first; the front one only for a call that
        // arrived without a pane, which is a helper started outside Vitra.
        let owner = pane.flatMap { controller(owningPaneID: $0) }
        guard let controller = owner ?? frontController else {
            throw ToolError("Vitra has no window open")
        }
        // A tool call arrives with the app in the back, often on another Space.
        // Whatever it is about — a page, a file — is for the user to see, so the
        // window comes forward with it. Without this the browser opens in a
        // window nobody is looking at, which reads as "the agent says it opened
        // but nothing is here".
        surface()
        return controller
    }

    @MainActor func preview(_ target: PreviewTarget, pane: String?) throws {
        try toolWindow(pane: pane).preview(target)
    }

    @MainActor func browser(pane: String?, agent: String?) throws -> BrowserView {
        let controller = try toolWindow(pane: pane)
        return controller.browser(for: pane.flatMap { controller.pane(withID: $0) })
    }
}

/// The socket's view of the runner: a plain executor that hops to the main actor.
struct GUIToolExecutor: ToolExecutor {
    let runner: ToolRunner

    func run(tool: String, arguments: JSONValue, pane: String?) async throws -> String {
        try await runner.run(tool: tool, arguments: arguments, pane: pane)
    }
}

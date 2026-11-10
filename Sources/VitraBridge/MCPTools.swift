import Foundation

/// The tools Vitra exposes to an agent, and their schemas.
///
/// The list is static and lives here rather than in the GUI so that
/// `vitra mcp` can answer `tools/list` even when no window is open — otherwise
/// the agent's MCP client would fail to start whenever Vitra happens to be
/// closed.
public enum MCPTools {
    /// The tools that act on the window: they are forwarded to the running app.
    public static let panel: [JSONValue] = [
        tool(
            "preview_file",
            "Show a file in Vitra's side panel: images, PDFs, HTML, SVG, and text or source files. The panel opens if it is closed.",
            properties: ["path": string("Absolute path to an existing file.")],
            required: ["path"]
        ),
        tool(
            "browser_open",
            "Open a URL in your own tab of Vitra's browser and wait for it to finish loading. Returns the final URL and page title. Every agent has a tab of its own: what you open, click and type never disturbs another agent's page, nor theirs yours. A tab left untouched for 30 minutes is closed.",
            properties: ["url": string("URL to open. http, https, and file URLs are accepted.")],
            required: ["url"]
        ),
        tool(
            "browser_snapshot",
            "List the interactive and text-bearing elements of the current page, each with a ref to use with browser_click and browser_type. Invisible elements are left out. Take a fresh snapshot after anything that changes the page.",
            properties: ["tab": otherTab],
            required: []
        ),
        tool(
            "browser_click",
            "Click the element with the given ref from the most recent snapshot. If the click navigates, this waits for the new page and reports where it landed.",
            properties: ["ref": string("Element ref from browser_snapshot, such as e12.")],
            required: ["ref"]
        ),
        tool(
            "browser_type",
            "Type text into the element with the given ref, replacing what it holds. With submit, this waits for whatever the submission navigates to.",
            properties: [
                "ref": string("Element ref from browser_snapshot."),
                "text": string("Text to type."),
                "submit": ["type": "boolean", "description": "Press Enter afterwards. Defaults to false."],
            ],
            required: ["ref", "text"]
        ),
        tool(
            "browser_back",
            "Go back one step in the browser panel's history and wait for the page to load. Refs from an earlier snapshot do not survive it.",
            properties: [:],
            required: []
        ),
        tool(
            "browser_forward",
            "Go forward one step in the browser panel's history and wait for the page to load.",
            properties: [:],
            required: []
        ),
        tool(
            "browser_eval",
            "Evaluate JavaScript in the page and return the result as JSON. Runs in an isolated world: it can read and drive the DOM, but the page's own scripts cannot see it.",
            properties: ["script": string("JavaScript expression or statements. The last expression is returned.")],
            required: ["script"]
        ),
        tool(
            "browser_screenshot",
            "Save a PNG of the current page to ~/.vitra/screenshots and return its path. Read the file to look at it.",
            properties: ["tab": otherTab],
            required: []
        ),
        tool(
            "browser_console",
            "Return recent console messages from the page, oldest first.",
            properties: [
                "clear": ["type": "boolean", "description": "Empty the buffer after reading. Defaults to false."],
                "tab": otherTab,
            ],
            required: []
        ),
        tool(
            "terminal_read",
            "Read the project's shared terminal: a shell in Vitra's Terminal tab that the user types in too. Returns its last lines, prompts, commands and output as they appear on screen. Use it when the user refers to something they ran or saw there. It runs nothing.",
            properties: ["lines": ["type": "integer", "description": "How many trailing lines to return. Defaults to 80, at most 1000."]],
            required: []
        ),
        tool(
            "terminal_run",
            "Type one command into the project's shared terminal and return what it printed. The user sees it run and can take over. For what the user should watch or will want to keep using — a dev server, a long build, a log being followed; for everything else use your own shell. Fails if a program is already running there. Only the maestro can use it: a worker reads the terminal but does not type in it.",
            properties: [
                "command": string("The command line to type, one line."),
                "timeout_seconds": ["type": "integer", "description": "How long to wait for it to finish before returning what there is. Defaults to 60, at most 600. A command still running stays running."],
            ],
            required: ["command"]
        ),
        tool(
            "browser_tabs",
            "List the browser's tabs in this project: each one's id, whose it is, its page title and URL, and which is yours. Any agent may look at any tab — pass a tab's id as `tab` to browser_snapshot, browser_screenshot or browser_console — but only its owner can navigate, click or type in it.",
            properties: [:],
            required: []
        ),
    ]

    /// Looking is open to all; driving is not. Only the tools that read take this.
    private static let otherTab: JSONValue = [
        "type": "string",
        "description": "Id of another agent's tab to look at, from browser_tabs. Leave out for your own tab.",
    ]

    /// What a worker is served: the panel's tools, less the one that types
    /// in the shared terminal — that would be a way round the list of
    /// commands the maestro allowed it.
    public static let worker: [JSONValue] = panel.filter { $0["name"]?.stringValue != "terminal_run" } + MemoryTools.all

    /// Every tool `vitra mcp` serves: the panel's, the orchestrator's, and the notes.
    public static let all: [JSONValue] = panel + AgentTools.all + MemoryTools.all

    public static let names: [String] = all.compactMap { $0["name"]?.stringValue }

    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func tool(
        _ name: String,
        _ description: String,
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ],
        ]
    }
}

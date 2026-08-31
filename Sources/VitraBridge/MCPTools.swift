import Foundation

/// The tools Vitra exposes to an agent, and their schemas.
///
/// The list is static and lives here rather than in the GUI so that
/// `vitra mcp` can answer `tools/list` even when no window is open — otherwise
/// the agent's MCP client would fail to start whenever Vitra happens to be
/// closed.
public enum MCPTools {
    public static let all: [JSONValue] = [
        tool(
            "preview_file",
            "Show a file in Vitra's side panel: images, PDFs, HTML, SVG, and text or source files. The panel opens if it is closed.",
            properties: ["path": string("Absolute path to an existing file.")],
            required: ["path"]
        ),
        tool(
            "browser_open",
            "Open a URL in Vitra's browser panel and wait for it to finish loading. Returns the final URL and page title.",
            properties: ["url": string("URL to open. http, https, and file URLs are accepted.")],
            required: ["url"]
        ),
        tool(
            "browser_snapshot",
            "List the interactive and text-bearing elements of the current page, each with a ref to use with browser_click and browser_type. Invisible elements are left out. Take a fresh snapshot after anything that changes the page.",
            properties: [:],
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
            properties: [:],
            required: []
        ),
        tool(
            "browser_console",
            "Return recent console messages from the page, oldest first.",
            properties: ["clear": ["type": "boolean", "description": "Empty the buffer after reading. Defaults to false."]],
            required: []
        ),
    ]

    public static let names: [String] = all.compactMap { $0["name"]?.stringValue }

    private static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func tool(
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

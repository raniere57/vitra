import Foundation

/// Everything `~/.vitra/config.toml` can say.
///
/// Reading is forgiving on purpose: an unknown key or a malformed value leaves
/// the default in place and adds a line to `problems`, which the preferences
/// window shows. A typo in a config file should never stop a terminal opening.
public struct Config: Equatable, Sendable {
    public var fontName: String = "Menlo"
    public var fontSize: Double = 13
    public var theme: Theme = .dark
    /// 0.5–1. Below 1 the window is translucent.
    public var opacity: Double = 1
    /// Frosts what is behind a translucent window.
    public var blur: Bool = false
    public var padding: Double = 8
    public var scrollbackLines: Int = 10_000
    /// Teaches the shell to mark where commands begin and end (OSC 133).
    public var shellIntegration: Bool = true
    /// Draws the gutter that separates one command from the next.
    public var commandBlocks: Bool = true
    /// A blank line before each prompt, so blocks are separated by space.
    public var blockSpacing: Bool = true
    /// Colours the stock zsh prompt. A prompt you have styled is left alone.
    public var colorPrompt: Bool = true
    /// Sets CLICOLOR, so `ls` and friends colour their output.
    public var colorDefaults: Bool = true
    /// What the cursor looks like, whatever the program running asks for.
    ///
    /// `.auto` is the program's own choice; anything else wins over it. The
    /// default is a bar because it stands exactly where the next character
    /// lands, and a block leaves that ambiguous: it covers the character after
    /// the insertion point rather than marking the point itself.
    public var cursorStyle: CursorStyleSetting = .bar
    /// nil means the user's login shell.
    public var shell: String?
    /// Menu action name to key equivalent, as in `split_right = "d"`.
    ///
    /// Always complete: the file overrides entries one at a time, so the app
    /// never has to merge defaults itself.
    public var keybindings: [String: String] = Config.defaultKeybindings

    public static let defaultKeybindings: [String: String] = [
        "new_tab": "t",
        "split_right": "d",
        "close_pane": "w",
        "preview_panel": "p",
        "folder_sidebar": "s",
        "sessions_sidebar": "c",
        "clear": "k",
    ]

    public init() {}

    public static let path = Vitra.supportDirectory.appendingPathComponent("config.toml")

    /// Reads the file, or returns the defaults when it is not there.
    public static func load(from url: URL = Config.path) -> (config: Config, problems: [String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (Config(), [])
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> (config: Config, problems: [String]) {
        var config = Config()
        var problems: [String] = []

        let root: [String: TOMLValue]
        do {
            root = try TOML.parse(text)
        } catch {
            return (config, ["config.toml: \(error)"])
        }

        if let value = root["font"]?.tableValue {
            if let name = value["family"]?.stringValue { config.fontName = name }
            if let size = value["size"]?.doubleValue {
                if (6...72).contains(size) {
                    config.fontSize = size
                } else {
                    problems.append("font.size must be between 6 and 72")
                }
            }
        }

        if let window = root["window"]?.tableValue {
            if let opacity = window["opacity"]?.doubleValue {
                if (0.5...1).contains(opacity) {
                    config.opacity = opacity
                } else {
                    problems.append("window.opacity must be between 0.5 and 1")
                }
            }
            if let blur = window["blur"]?.boolValue { config.blur = blur }
            if let padding = window["padding"]?.doubleValue {
                config.padding = min(max(padding, 0), 64)
            }
        }

        if let terminal = root["terminal"]?.tableValue {
            if let scrollback = terminal["scrollback"]?.intValue {
                config.scrollbackLines = max(0, scrollback)
            }
            if let shell = terminal["shell"]?.stringValue, !shell.isEmpty {
                config.shell = shell
            }
            if let value = terminal["shell_integration"]?.boolValue { config.shellIntegration = value }
            if let value = terminal["command_blocks"]?.boolValue { config.commandBlocks = value }
            if let value = terminal["block_spacing"]?.boolValue { config.blockSpacing = value }
            if let value = terminal["color_prompt"]?.boolValue { config.colorPrompt = value }
            if let value = terminal["color_defaults"]?.boolValue { config.colorDefaults = value }
            if let value = terminal["cursor_style"]?.stringValue {
                if let style = CursorStyleSetting(rawValue: value) {
                    config.cursorStyle = style
                } else {
                    problems.append(
                        "terminal.cursor_style must be one of: "
                            + CursorStyleSetting.allCases.map(\.rawValue).joined(separator: ", ")
                    )
                }
            }
        }

        if let keys = root["keybindings"]?.tableValue {
            for (action, value) in keys {
                guard Config.defaultKeybindings[action] != nil else {
                    problems.append("unknown action: keybindings.\(action)")
                    continue
                }
                guard let key = value.stringValue, key.count == 1 else {
                    problems.append("keybindings.\(action) must be a single character")
                    continue
                }
                config.keybindings[action] = key
            }
        }

        return (applyTheme(to: config, root: root, problems: &problems), problems)
    }

    /// Themes are read last: a `[theme]` table overrides the named theme's
    /// colours one field at a time, so a file can pick "light" and still change
    /// only the cursor.
    private static func applyTheme(
        to config: Config,
        root: [String: TOMLValue],
        problems: inout [String]
    ) -> Config {
        var config = config

        if let name = root["theme"]?.stringValue {
            guard let theme = Theme.named(name) else {
                problems.append("unknown theme: \(name)")
                return config
            }
            config.theme = theme
            return config
        }

        guard let table = root["theme"]?.tableValue else { return config }

        if let name = table["name"]?.stringValue {
            if let theme = Theme.named(name) {
                config.theme = theme
            } else {
                problems.append("unknown theme: \(name)")
            }
        }

        var theme = config.theme
        for (key, target) in [
            ("background", \Theme.background),
            ("foreground", \Theme.foreground),
            ("cursor", \Theme.cursor),
        ] as [(String, WritableKeyPath<Theme, TerminalColor>)] {
            guard let raw = table[key]?.stringValue else { continue }
            guard let color = TerminalColor(hex: raw) else {
                problems.append("theme.\(key) is not a colour: \(raw)")
                continue
            }
            theme[keyPath: target] = color
        }

        if let entries = table["palette"]?.arrayValue {
            guard entries.count == 16 else {
                problems.append("theme.palette needs exactly 16 colours, found \(entries.count)")
                config.theme = theme
                return config
            }
            let colors = entries.compactMap { $0.stringValue.flatMap(TerminalColor.init(hex:)) }
            if colors.count == 16 {
                theme.palette = colors
            } else {
                problems.append("theme.palette holds something that is not a colour")
            }
        }

        config.theme = theme
        return config
    }

    /// The file this configuration would be written as.
    ///
    /// Used by the preferences window, and to lay down a starting file the first
    /// time Vitra runs, so there is something to edit.
    public func toml() -> String {
        let shellLine = shell.map { "shell = \"\($0)\"" } ?? "# shell = \"/bin/zsh\"     # defaults to your login shell"
        let keybindingLines = Config.defaultKeybindings.keys.sorted()
            .map { "\($0) = \"\(keybindings[$0] ?? Config.defaultKeybindings[$0]!)\"" }
            .joined(separator: "\n        ")
        let palette = theme.palette
            .map { "\"\($0.hex)\"" }
            .chunked(into: 4)
            .map { "  " + $0.joined(separator: ", ") + "," }
            .joined(separator: "\n")

        return """
        # Vitra configuration. Saved changes apply to open windows immediately.

        [font]
        family = "\(fontName)"
        size = \(clean(fontSize))

        [window]
        opacity = \(clean(opacity))   # 0.5 to 1
        blur = \(blur)
        padding = \(clean(padding))

        [terminal]
        scrollback = \(scrollbackLines)
        # marks where each command starts and ends, and draws the gutter for it
        shell_integration = \(shellIntegration)
        command_blocks = \(commandBlocks)
        block_spacing = \(blockSpacing)
        # colour the stock zsh prompt, and set CLICOLOR for ls and friends
        color_prompt = \(colorPrompt)
        color_defaults = \(colorDefaults)
        # auto follows the program; bar, block, underline and hollow overrule it
        cursor_style = "\(cursorStyle.rawValue)"
        \(shellLine)

        [theme]
        name = "\(theme.name)"
        background = "\(theme.background.hex)"
        foreground = "\(theme.foreground.hex)"
        cursor = "\(theme.cursor.hex)"
        # eight normal colours, then eight bright
        palette = [
        \(palette)
        ]

        [keybindings]
        # single characters, always combined with Command
        \(keybindingLines)

        """
    }

    /// Whole numbers print without a pointless `.0`.
    private func clean(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

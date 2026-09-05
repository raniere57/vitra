import Foundation
import Testing
@testable import VitraCore

@Suite("Configuration")
struct ConfigTests {
    @Test func anAbsentFileGivesTheDefaults() {
        let missing = URL(fileURLWithPath: "/tmp/vitra-absent-\(UUID().uuidString)/config.toml")
        let (config, problems) = Config.load(from: missing)
        #expect(config == Config())
        #expect(problems.isEmpty)
    }

    @Test func everySectionIsRead() {
        let (config, problems) = Config.parse("""
        [font]
        family = "SF Mono"
        size = 14

        [window]
        opacity = 0.9
        blur = true
        padding = 12

        [terminal]
        scrollback = 5000
        shell = "/bin/zsh"

        [theme]
        name = "light"

        [keybindings]
        split_right = "e"
        """)

        #expect(problems.isEmpty)
        #expect(config.fontName == "SF Mono")
        #expect(config.fontSize == 14)
        #expect(config.opacity == 0.9)
        #expect(config.blur)
        #expect(config.padding == 12)
        #expect(config.scrollbackLines == 5000)
        #expect(config.shell == "/bin/zsh")
        #expect(config.theme.name == "light")
        #expect(config.keybindings["split_right"] == "e")
        // Untouched actions keep their defaults, so the app never merges.
        #expect(config.keybindings["new_tab"] == "t")
    }

    /// A typo must never stop a terminal from opening.
    @Test func badValuesKeepTheDefaultAndAreReported() {
        let (config, problems) = Config.parse("""
        [font]
        size = 900

        [window]
        opacity = 4

        [theme]
        name = "solarized"
        cursor = "not a colour"
        """)

        #expect(config.fontSize == Config().fontSize)
        #expect(config.opacity == 1)
        #expect(config.theme == Theme.dark)
        #expect(problems.count == 4)
    }

    @Test func aThemeCanBePickedAndThenAdjusted() {
        let (config, problems) = Config.parse("""
        [theme]
        name = "light"
        cursor = "#ff0000"
        """)
        #expect(problems.isEmpty)
        #expect(config.theme.background == Theme.light.background)
        #expect(config.theme.cursor == TerminalColor(hex: "#ff0000"))
    }

    @Test func aFullPaletteReplacesTheThemes() {
        let colours = (0..<16).map { "\"#0000\(String(format: "%02x", $0))\"" }.joined(separator: ", ")
        let (config, problems) = Config.parse("[theme]\npalette = [\(colours)]")
        #expect(problems.isEmpty)
        #expect(config.theme.palette.count == 16)
        #expect(config.theme.palette[15] == TerminalColor(hex: "#00000f"))
    }

    @Test func aShortPaletteIsRefusedRatherThanHalfApplied() {
        let (config, problems) = Config.parse("[theme]\npalette = [\"#000000\", \"#ffffff\"]")
        #expect(config.theme.palette == Theme.dark.palette)
        #expect(problems.contains { $0.contains("16 colours") })
    }

    /// What the preferences window writes has to be what the parser reads.
    @Test func whatIsWrittenIsWhatIsRead() {
        var config = Config()
        config.fontName = "Menlo"
        config.fontSize = 15
        config.opacity = 0.85
        config.blur = true
        config.padding = 10
        config.scrollbackLines = 2500
        config.shell = "/bin/bash"
        config.theme = .light
        config.keybindings["split_right"] = "e"
        config.cursorStyle = .underline

        let (reloaded, problems) = Config.parse(config.toml())
        #expect(problems.isEmpty)
        #expect(reloaded == config)
    }

    @Test func theCursorStyleIsReadAndAnUnknownOneIsReported() {
        let (config, problems) = Config.parse("""
        [terminal]
        cursor_style = "block"
        """)
        #expect(config.cursorStyle == .block)
        #expect(problems.isEmpty)

        let (fallback, complaints) = Config.parse("""
        [terminal]
        cursor_style = "sparkle"
        """)
        // A typo leaves the default in place rather than taking the cursor away.
        #expect(fallback.cursorStyle == .bar)
        #expect(complaints.count == 1)
    }

    @Test func the256ColourPaletteIsGeneratedFromTheSixteen() {
        let palette = Theme.dark.fullPalette
        #expect(palette.count == 256)
        #expect(palette[0] == Theme.dark.palette[0])
        // Index 196 is the standard bright red of the colour cube.
        #expect(palette[196] == TerminalColor(red: 255, green: 0, blue: 0))
        #expect(palette[255] == TerminalColor(red: 238, green: 238, blue: 238))
    }

    @Test func colorsRoundTripThroughHex() {
        #expect(TerminalColor(hex: "#fff") == TerminalColor(red: 255, green: 255, blue: 255))
        #expect(TerminalColor(hex: "1a2b3c")?.hex == "#1a2b3c")
        #expect(TerminalColor(hex: "nope") == nil)
    }
}

@Test func claudeFlagsSurviveTheRoundTrip() {
    var config = Config()
    config.claudeFlags = "--dangerously-skip-permissions"
    let (reloaded, problems) = Config.parse(config.toml())
    #expect(problems.isEmpty)
    #expect(reloaded.claudeFlags == "--dangerously-skip-permissions")
}

@Test func launchFlagsLandOnTheResumeLine() {
    Harness.launchFlags[.claudeCode] = "--dangerously-skip-permissions"
    defer { Harness.launchFlags[.claudeCode] = nil }
    #expect(Harness.claudeCode.resumeLine(id: "abc") == "claude --dangerously-skip-permissions --resume abc\n")
    #expect(Harness.openCode.resumeLine(id: "abc") == "opencode --session abc\n")
    #expect(Harness.codex.resumeLine(id: "abc") == "codex resume abc\n")
}

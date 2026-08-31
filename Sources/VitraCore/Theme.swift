import Foundation

/// The colours a terminal draws with.
///
/// Sixteen ANSI colours plus the three the terminal owns itself. The 256-colour
/// cube above index 15 is generated, not configured: nobody hand-picks 240
/// colours, and the standard formula is what programs expect.
public struct Theme: Equatable, Sendable {
    public var name: String
    public var background: TerminalColor
    public var foreground: TerminalColor
    public var cursor: TerminalColor
    /// Indices 0–15: eight normal, then eight bright.
    public var palette: [TerminalColor]

    public init(
        name: String,
        background: TerminalColor,
        foreground: TerminalColor,
        cursor: TerminalColor,
        palette: [TerminalColor]
    ) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.palette = palette
    }

    public static let dark = Theme(
        name: "dark",
        background: TerminalColor(hex: "#0d0d11")!,
        foreground: TerminalColor(hex: "#d6d6dd")!,
        cursor: TerminalColor(hex: "#e8e8ef")!,
        palette: [
            "#15151a", "#e05561", "#8cc265", "#d6a75c",
            "#5aa5e0", "#c07ce8", "#4fb8b0", "#c0c0c8",
            "#4a4a55", "#ff7b86", "#a9e07f", "#f0c674",
            "#7cc0ff", "#d9a2ff", "#6fdad2", "#f0f0f5",
        ].compactMap { TerminalColor(hex: $0) }
    )

    /// A light theme that is actually light: paper, not grey.
    public static let light = Theme(
        name: "light",
        background: TerminalColor(hex: "#faf9f6")!,
        foreground: TerminalColor(hex: "#2b2b33")!,
        cursor: TerminalColor(hex: "#2b2b33")!,
        palette: [
            "#3b3b45", "#c0392f", "#4a7d33", "#9a6a12",
            "#2b6cb0", "#7b3fa0", "#177f78", "#d8d6d0",
            "#7a7a86", "#e05561", "#5c9a41", "#b98420",
            "#3b83c8", "#9557b8", "#22998f", "#f4f3ef",
        ].compactMap { TerminalColor(hex: $0) }
    )

    public static let builtIn: [Theme] = [.dark, .light]

    public static func named(_ name: String) -> Theme? {
        builtIn.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The full 256-colour palette: the configured sixteen, then the standard
    /// 6×6×6 cube and the greyscale ramp that programs assume are there.
    public var fullPalette: [TerminalColor] {
        var colors = palette
        while colors.count < 16 { colors.append(.black) }

        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for red in steps {
            for green in steps {
                for blue in steps {
                    colors.append(TerminalColor(red: red, green: green, blue: blue))
                }
            }
        }
        for index in 0..<24 {
            let level = UInt8(8 + index * 10)
            colors.append(TerminalColor(red: level, green: level, blue: level))
        }
        return colors
    }
}

extension TerminalColor {
    /// Reads `#rrggbb`, or `rrggbb`, or the three-digit short form.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }

        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }

        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }
}

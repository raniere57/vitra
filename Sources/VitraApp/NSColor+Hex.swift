import AppKit
import VitraCore

extension NSColor {
    /// `#rrggbb`, the form bookmarks and themes are written in.
    convenience init?(hex: String) {
        guard let color = TerminalColor(hex: hex) else { return nil }
        self.init(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}

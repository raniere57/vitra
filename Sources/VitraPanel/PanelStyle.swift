import AppKit

/// The panel's palette and metrics.
///
/// The panel sits against a black terminal, so it is built from near-black
/// surfaces separated by hairlines rather than from the system's light chrome.
/// One place to change, since every subview reads from here.
public enum PanelStyle {
    public static let surface = NSColor(white: 0.07, alpha: 1)
    public static let headerSurface = NSColor(white: 0.11, alpha: 1)
    public static let hairline = NSColor(white: 0.22, alpha: 1)
    public static let primaryText = NSColor(white: 0.92, alpha: 1)
    public static let secondaryText = NSColor(white: 0.52, alpha: 1)

    public static let headerHeight: CGFloat = 30
    public static let defaultWidth: CGFloat = 420
    public static let minimumWidth: CGFloat = 260

    public static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

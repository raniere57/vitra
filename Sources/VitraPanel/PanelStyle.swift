import AppKit

/// The panel's names for `Theme`'s tokens. Nothing is defined here: the panel
/// takes the cockpit's palette, so a change of colour is made once, in `Theme`.
public enum PanelStyle {
    public static let surface = Theme.panel
    public static let headerSurface = Theme.ground
    public static let hairline = Theme.softLine
    public static let primaryText = Theme.text
    public static let secondaryText = Theme.muted

    public static let headerHeight = Theme.headerHeight
    public static let defaultWidth = Theme.workersWidth
    public static let minimumWidth = Theme.minimumPanelWidth
    public static let dividerGrab = Theme.dividerGrab

    public static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        Theme.mono(size, weight)
    }
}

import AppKit

/// The look of Vitra's dark interface, in one place: colours, spacing, radii,
/// type roles and fixed heights. The cockpit (VitraApp) and the file/browser
/// panel (VitraPanel) both read from here, so they cannot drift apart.
///
/// A graphite ground with a single amber accent. The accent is reserved for
/// what is live — the maestro, a running worker, the best-ranked row — so that
/// at a glance amber means "something is working here" and nothing else
/// competes for it.
public enum Theme {
    // MARK: Colours

    public static let ground = color(0x14161A)
    public static let bar = color(0x0E1013)
    public static let panel = color(0x101216)
    public static let raised = color(0x1A1D22)
    public static let tab = color(0x1E2228)

    public static let line = color(0x262A31)
    public static let softLine = color(0x1E2228)
    public static let raisedLine = color(0x2C313A)
    public static let controlLine = color(0x343943)

    public static let text = color(0xE9E6DF)
    public static let muted = color(0xA9AFB9)
    public static let code = color(0xC9CDD4)

    public static let accent = color(0xE8A33D)
    public static let success = color(0x6FCF97)
    public static let danger = color(0xE5645A)
    /// The danger colour as text: the dot's red is too dark to read at 12 pt.
    public static let dangerText = color(0xEE8F87)

    // MARK: Spacing

    /// The spacing scale: 2 / 4 / 6 / 8 / 12 / 16 / 24.
    public enum Space {
        public static let hair: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
    }

    /// The one horizontal inset of content: headers, tab bars, list bodies and
    /// strips all start and end this far from the edge, so their left edges
    /// line up from tab to tab.
    public static let inset = Space.xl

    // MARK: Radii

    public enum Radius {
        /// A status dot.
        public static let dot: CGFloat = 3
        /// A thumbnail.
        public static let thumb: CGFloat = 5
        /// A control, chip, pill or tab.
        public static let control: CGFloat = 6
        /// A card or a panel of text.
        public static let card: CGFloat = 8
    }

    // MARK: Type roles

    /// A heading that stands on its own, such as an empty state's.
    public static var display: NSFont { ui(15, .semibold) }
    /// The name of a thing: a row's title, the pane's name.
    public static var title: NSFont { ui(13, .semibold) }
    /// A control's text: tabs, pills, buttons.
    public static var label: NSFont { ui(12, .medium) }
    /// Running text.
    public static var body: NSFont { ui(12) }
    /// A quiet note under or beside something.
    public static var caption: NSFont { ui(11) }
    /// Numbers, paths, hashes, times: monospaced.
    public static var meta: NSFont { mono(11) }
    /// A column header or section title, set in capitals.
    public static var micro: NSFont { mono(10, .medium) }

    public static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    public static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Monospaced digits in the UI face, for figures that must line up.
    public static func figures(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    // MARK: Heights and widths

    public static let barHeight: CGFloat = 44
    /// Every header: the maestro's, the side tabs', the files', the preview's,
    /// the browser's tab strip and address row.
    public static let headerHeight: CGFloat = 32
    public static let rowHeight: CGFloat = 30
    public static let footerHeight: CGFloat = 40
    /// An icon set inline with text.
    public static let iconSize: CGFloat = 14

    public static let workersWidth: CGFloat = 420
    public static let minimumPanelWidth: CGFloat = 260
    /// Room for the window's own close, minimise and zoom buttons.
    public static let trafficLightInset: CGFloat = 84

    /// How far either side of a divider still counts as grabbing it.
    ///
    /// The line itself is one pixel, which is right to look at and impossible to
    /// hit; the pointer gets a band five times that.
    public static let dividerGrab: CGFloat = 5

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

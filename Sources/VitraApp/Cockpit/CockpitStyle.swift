import AppKit

/// The cockpit's look, in one place: every colour, face and fixed size it uses.
///
/// A graphite ground with a single amber accent. The accent is reserved for
/// what is live — the maestro, a running worker — so that at a glance amber
/// means "something is working here" and nothing else competes for it.
enum CockpitStyle {
    static let ground = color(0x14161A)
    static let bar = color(0x0E1013)
    static let panel = color(0x101216)
    static let raised = color(0x1A1D22)
    static let tab = color(0x1E2228)

    static let line = color(0x262A31)
    static let softLine = color(0x1E2228)
    static let raisedLine = color(0x2C313A)
    static let controlLine = color(0x343943)

    static let text = color(0xE9E6DF)
    static let muted = color(0xA9AFB9)
    static let code = color(0xC9CDD4)

    static let accent = color(0xE8A33D)
    static let success = color(0x6FCF97)
    static let danger = color(0xE5645A)
    /// The danger colour as text: the dot's red is too dark to read at 12 pt.
    static let dangerText = color(0xEE8F87)

    static let barHeight: CGFloat = 44
    static let headerHeight: CGFloat = 40
    static let footerHeight: CGFloat = 46
    static let workersWidth: CGFloat = 420
    /// Room for the window's own close, minimise and zoom buttons.
    static let trafficLightInset: CGFloat = 84

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension NSView {
    /// A layer-backed view filled with one colour.
    static func filled(_ color: NSColor, cornerRadius: CGFloat = 0) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// Adds `child` filling this view, held there by constraints.
    ///
    /// Not by an autoresizing mask: the cockpit builds its views before the
    /// window has laid anything out, and a mask taken against a container that
    /// is still zero-sized turns into constraints with absurd constants.
    func addFilling(_ child: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
    }

    /// A small rounded plate holding `views` in a row: one fact of a header,
    /// set apart from its neighbours instead of run together with them.
    static func pill(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        let pill = filled(CockpitStyle.raised, cornerRadius: 6)
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        pill.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
        ])
        return pill
    }

    /// A one-point rule in the given colour.
    static func rule(_ color: NSColor, vertical: Bool = false) -> NSView {
        let view = filled(color)
        let side = vertical ? view.widthAnchor : view.heightAnchor
        side.constraint(equalToConstant: 1).isActive = true
        return view
    }
}

extension NSTextField {
    /// A label that goes on to further lines when its line is too short for
    /// it, and is only cut after `lines` of them.
    static func wrapping(_ text: String, font: NSFont, color: NSColor, lines: Int = 0) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = lines
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A single-line label that never wraps and gives way before its neighbours.
    static func label(_ text: String = "", font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

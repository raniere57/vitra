import AppKit
import VitraPanel

/// The cockpit's name for the shared `Theme` (VitraPanel), which holds every
/// colour, face and fixed size. Nothing is defined here. Qualified because
/// VitraCore has a `Theme` of its own: the terminal's colours.
typealias CockpitStyle = VitraPanel.Theme

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
        row.spacing = CockpitStyle.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        let pill = filled(CockpitStyle.raised, cornerRadius: CockpitStyle.Radius.control)
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        pill.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: CockpitStyle.Space.xs),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -CockpitStyle.Space.xs),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: CockpitStyle.Space.md),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -CockpitStyle.Space.md),
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

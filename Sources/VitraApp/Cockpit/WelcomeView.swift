import AppKit

/// What the cockpit shows with no project open: the first-run guide.
///
/// One column, centred a little above the middle: the mark, one line saying
/// what Vitra is, the three steps of using it, the one thing to do now, and a
/// quiet line of the shortcuts worth knowing first. Nothing else competes —
/// the amber is spent on the core of the mark and the button.
final class WelcomeView: NSView {
    static let line = "Um maestro que delega a operários, e você no comando."
    static let steps: [(symbol: String, text: String)] = [
        ("folder", "Abra uma pasta de projeto"),
        ("text.bubble", "Diga ao maestro o que quer"),
        ("atom", "Acompanhe no Palco e ajuste a escalação no Ranking"),
    ]
    static let shortcuts = "⌘O abre um projeto · ⌘F busca na conversa · ⌘/ mostra todos os atalhos"

    /// How wide one step's text may run before it wraps.
    private static let stepWidth: CGFloat = 200

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.ground.cgColor

        let mark = VitraMark()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 120),
            mark.heightAnchor.constraint(equalToConstant: 120),
        ])
        mark.setAccessibilityElement(true)
        mark.setAccessibilityRole(.image)
        mark.setAccessibilityLabel("Vitra")

        let name = NSTextField.label("VITRA", font: CockpitStyle.mono(11, .semibold), color: CockpitStyle.muted)
        name.attributedStringValue = NSAttributedString(string: "VITRA", attributes: [
            .font: CockpitStyle.mono(11, .semibold), .foregroundColor: CockpitStyle.muted, .kern: 3,
        ])
        let headline = NSTextField.label(Self.line, font: CockpitStyle.ui(20, .semibold), color: CockpitStyle.text)
        headline.alignment = .center
        headline.lineBreakMode = .byWordWrapping
        headline.maximumNumberOfLines = 2

        let open = PrimaryButton(title: "Abrir projeto…", keys: "⌘O", target: target, action: action)

        let shortcuts = NSTextField.label("", font: CockpitStyle.caption, color: CockpitStyle.muted)
        shortcuts.attributedStringValue = HintStrip.styled(Self.shortcuts)
        shortcuts.alignment = .center

        let column = NSStackView(views: [mark, name, headline, Self.stepsRow(), open, shortcuts])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.setCustomSpacing(CockpitStyle.Space.lg, after: mark)
        column.setCustomSpacing(CockpitStyle.Space.md, after: name)
        column.setCustomSpacing(36, after: headline)
        column.setCustomSpacing(40, after: column.arrangedSubviews[3])
        column.setCustomSpacing(CockpitStyle.Space.xxl, after: open)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // A little above the middle: the eye's centre of a screen is not its
        // measured one.
        let centreY = column.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -CockpitStyle.Space.xxl)
        centreY.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            centreY,
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: CockpitStyle.Space.xxl),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: CockpitStyle.Space.xxl),
            headline.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The three steps side by side, each an icon on a small plate, its number
    /// and a line or two of text, with a hairline joining them.
    private static func stepsRow() -> NSView {
        let views = steps.enumerated().map { index, step in Self.step(number: index + 1, symbol: step.symbol, text: step.text) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = CockpitStyle.Space.xxl
        return row
    }

    private static func step(number: Int, symbol: String, text: String) -> NSView {
        let plate = NSView.filled(CockpitStyle.raised, cornerRadius: CockpitStyle.Radius.card)
        plate.layer?.borderWidth = 1
        plate.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.contentTintColor = CockpitStyle.text
        icon.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(icon)
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: 40),
            plate.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])

        let numeral = NSTextField.label("\(number)", font: CockpitStyle.mono(11, .semibold), color: CockpitStyle.accent)
        let label = NSTextField.wrapping(text, font: CockpitStyle.ui(13), color: CockpitStyle.text, lines: 2)
        label.alignment = .center
        label.preferredMaxLayoutWidth = stepWidth
        label.widthAnchor.constraint(equalToConstant: stepWidth).isActive = true

        let column = NSStackView(views: [plate, numeral, label])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = CockpitStyle.Space.sm
        column.setCustomSpacing(CockpitStyle.Space.lg, after: plate)
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.staticText)
        column.setAccessibilityLabel("Passo \(number): \(text)")
        return column
    }
}

/// The one filled button of the cockpit: amber, dark text, and its chord
/// beside the title, quieter.
private final class PrimaryButton: NSButton {
    private static let height: CGFloat = 36
    private static let padding: CGFloat = 20

    init(title: String, keys: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.accent.cgColor
        layer?.cornerRadius = Self.height / 2
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: CockpitStyle.ui(13, .semibold), .foregroundColor: CockpitStyle.ground,
        ])
        text.append(NSAttributedString(string: "   " + keys, attributes: [
            .font: CockpitStyle.mono(11, .medium), .foregroundColor: CockpitStyle.ground.withAlphaComponent(0.6),
        ]))
        attributedTitle = text
        setAccessibilityLabel(title)
        // ⏎ opens it too, the way the default button of a sheet does.
        keyEquivalent = "\r"
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: attributedTitle.size().width + 2 * Self.padding, height: Self.height)
    }

    /// Pressed: the amber a shade darker, so the click is felt.
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        let pressed = CockpitStyle.accent.blended(withFraction: 0.18, of: .black) ?? CockpitStyle.accent
        layer?.backgroundColor = (flag ? pressed : CockpitStyle.accent).cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

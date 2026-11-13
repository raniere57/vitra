import AppKit

/// Whether the one-time shortcut hint at the top of the side panel has been
/// put away. Remembered in the user's defaults, not in the cockpit's state: it
/// is about the person, not about any project, and survives closing them all.
struct FirstRunHint {
    static let key = "cockpit.shortcutHintDismissed"
    static let text = "⌥⌘1–8 trocam de aba · ⌘F busca na conversa · ⌘/ mostra todos os atalhos"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDismissed: Bool { defaults.bool(forKey: Self.key) }

    func dismiss() { defaults.set(true, forKey: Self.key) }
}

/// The strip itself: three chords and what they do, and a way to say "got it".
final class HintStrip: NSView {
    var onDismiss: (() -> Void)?

    init(text: String = FirstRunHint.text) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.raised.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: "atalhos") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.contentTintColor = CockpitStyle.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)

        // Two lines on purpose, the last chord on its own: the narrow panel
        // cannot hold all three, and a break chosen here reads better than
        // one that falls mid-phrase.
        let styled = NSMutableAttributedString(attributedString: Self.styled(text, breakingBeforeLast: true))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
        // A label of two set lines, not a wrapping one: its height is known
        // before the panel's width is.
        let label = NSTextField(labelWithAttributedString: styled)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The text takes the row, so the close button sits at the far edge.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let close = NSButton(title: "", target: self, action: #selector(dismiss))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dispensar")
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        close.contentTintColor = CockpitStyle.muted
        close.isBordered = false
        close.toolTip = "Entendi — não mostrar de novo"
        close.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, label, close])
        row.alignment = .centerY
        row.spacing = CockpitStyle.Space.md
        row.distribution = .fill
        row.setHuggingPriority(.required, for: .vertical)
        row.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.lg, left: CockpitStyle.inset, bottom: CockpitStyle.Space.lg, right: CockpitStyle.Space.lg)
        addFilling(row)

        let rule = NSView.rule(CockpitStyle.softLine)
        addSubview(rule)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The chords in the text's colour and a monospaced face, what they do
    /// muted: "⌘F busca na conversa · ⌘/ mostra…", one chord per part.
    static func styled(_ text: String, breakingBeforeLast: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let separator = NSAttributedString(string: "  ·  ", attributes: [.font: CockpitStyle.caption, .foregroundColor: CockpitStyle.muted.withAlphaComponent(0.5)])
        let parts = text.components(separatedBy: " · ")
        for (index, part) in parts.enumerated() {
            if index > 0 {
                let isLast = index == parts.count - 1
                result.append(breakingBeforeLast && isLast ? NSAttributedString(string: "\n") : separator)
            }
            let words = part.split(separator: " ", maxSplits: 1).map(String.init)
            result.append(NSAttributedString(string: words.first ?? "", attributes: [.font: CockpitStyle.mono(11, .medium), .foregroundColor: CockpitStyle.text]))
            if words.count > 1 {
                result.append(NSAttributedString(string: " " + words[1], attributes: [.font: CockpitStyle.caption, .foregroundColor: CockpitStyle.muted]))
            }
        }
        return result
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}

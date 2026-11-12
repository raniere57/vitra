import AppKit

/// The maestro header's quiet note that the maestro runs an older Vitra:
/// "versão antiga" and a small "Atualizar"; once armed, "atualiza ao
/// terminar" and a × to take that back. Amber on the raised plate, like the
/// tab bar's warm chips: worth a glance, not an alarm.
///
/// Compact — the last thing the header gives up — the words go and a glyph
/// stands for them: ↻ to update, a clock and × while armed. The tooltips
/// still say it all.
final class MaestroUpdatePill: NSView {
    var onUpdate: (() -> Void)?
    var onCancel: (() -> Void)?

    private let label = NSTextField.label(font: CockpitStyle.label, color: CockpitStyle.accent)
    private let clock: NSImageView = {
        let icon = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: "atualiza ao terminar") ?? NSImage())
        icon.contentTintColor = CockpitStyle.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        return icon
    }()
    private lazy var button: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(pressed(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.cornerRadius = CockpitStyle.Radius.dot
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        return button
    }()
    private static let refresh = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Atualizar")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    private var phase: MaestroUpdateState.Phase = .current
    private(set) var isCompact = false
    /// The pill's width with its words and compact, for `HeaderFit`;
    /// measured whenever what it says changes.
    private(set) var widths: (full: CGFloat, compact: CGFloat) = (0, 0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = CockpitStyle.Radius.control
        layer?.borderWidth = 1
        layer?.backgroundColor = CockpitStyle.raised.cgColor
        layer?.borderColor = CockpitStyle.accent.withAlphaComponent(0.5).cgColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [clock, label, button])
        row.spacing = CockpitStyle.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // As tall as the header's other plates: a label and its padding, not
        // the button's taller frame.
        let plate = NSTextField.label("M", font: CockpitStyle.label, color: .clear).fittingSize.height + 2 * CockpitStyle.Space.xs
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: plate),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.sm),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        show(.outdated)
        show(.current)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ phase: MaestroUpdateState.Phase, compact: Bool? = nil) {
        let changed = phase != self.phase || widths.full == 0
        self.phase = phase
        if changed, phase != .current {
            apply(compact: false)
            let full = fittingSize.width
            apply(compact: true)
            widths = (full, fittingSize.width)
        }
        if let compact { isCompact = compact }
        apply(compact: isCompact)
        isHidden = phase == .current
    }

    private func apply(compact: Bool) {
        let isArmed = phase == .armed
        label.stringValue = isArmed ? "reinicia ao terminar" : "Vitra atualizado"
        label.isHidden = compact
        clock.isHidden = !(compact && isArmed)
        // "Atualizar" on an amber wash of its own, so it reads as the thing
        // to press; the × of the armed pill is just a mark.
        button.layer?.backgroundColor = isArmed ? nil : CockpitStyle.accent.withAlphaComponent(0.22).cgColor
        if !isArmed, compact {
            button.title = ""
            button.image = Self.refresh
            button.contentTintColor = CockpitStyle.text
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(
                string: isArmed ? "×" : "\u{2002}Reiniciar maestro\u{2002}",
                attributes: [
                    .font: isArmed ? CockpitStyle.ui(13, .medium) : CockpitStyle.ui(11, .semibold),
                    .foregroundColor: isArmed ? CockpitStyle.muted : CockpitStyle.text,
                ]
            )
        }
        button.toolTip = isArmed
            ? "Cancelar: o maestro segue na versão antiga"
            : "Reinicia o maestro na versão nova do Vitra e retoma a mesma conversa"
        button.setAccessibilityLabel(isArmed ? "Cancelar a atualização do maestro" : "Atualizar o maestro")
        toolTip = isArmed
            ? "O maestro reinicia na versão nova quando terminar o turno"
            : "Este maestro ainda roda a versão do Vitra anterior à instalada"
    }

    @objc private func pressed(_ sender: Any?) {
        phase == .armed ? onCancel?() : onUpdate?()
    }
}

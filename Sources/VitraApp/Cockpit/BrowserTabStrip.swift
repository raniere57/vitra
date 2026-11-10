import AppKit

/// The browser's own tabs: one per agent that has a page open, the user's,
/// and a button for one more.
final class BrowserTabStrip: NSView {
    struct Item: Equatable {
        let id: String
        let label: String
        let tip: String
    }

    var onSelect: ((String) -> Void)?
    var onNew: (() -> Void)?

    static let height: CGFloat = 32
    private static let widestChip: CGFloat = 170

    private let stack = NSStackView()
    private var items: [Item] = []
    private var current: String?
    private let showsNew: Bool

    /// `showsNew` is the "+" at the end, for a strip that can grow.
    init(showsNew: Bool = true) {
        self.showsNew = showsNew
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        addFilling(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ items: [Item], current: String?) {
        guard items != self.items || current != self.current else { return }
        (self.items, self.current) = (items, current)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let isCurrent = item.id == current
            let chip = NSButton(title: "", target: self, action: #selector(chipPressed(_:)))
            chip.tag = index
            chip.isBordered = false
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 6
            chip.layer?.backgroundColor = (isCurrent ? CockpitStyle.tab : .clear).cgColor
            chip.lineBreakMode = .byTruncatingTail
            chip.attributedTitle = NSAttributedString(string: " \(item.label) ", attributes: [
                .font: CockpitStyle.ui(11, isCurrent ? .semibold : .regular),
                .foregroundColor: isCurrent ? CockpitStyle.text : CockpitStyle.muted,
            ])
            chip.toolTip = item.tip
            chip.setAccessibilityLabel("Aba \(item.label)")
            chip.setAccessibilityValue(isCurrent ? "selecionada" : nil)
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: Self.widestChip).isActive = true
            chip.heightAnchor.constraint(equalToConstant: 22).isActive = true
            chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(chip)
        }
        guard showsNew else {
            stack.addArrangedSubview(NSView())
            return
        }
        let add = NSButton(title: "+", target: self, action: #selector(newPressed))
        add.isBordered = false
        add.attributedTitle = NSAttributedString(string: " + ", attributes: [
            .font: CockpitStyle.ui(13, .medium), .foregroundColor: CockpitStyle.muted,
        ])
        add.toolTip = "Nova aba sua"
        add.setAccessibilityLabel("Nova aba")
        stack.addArrangedSubview(add)
        stack.addArrangedSubview(NSView())
    }

    @objc private func chipPressed(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect?(items[sender.tag].id)
    }

    @objc private func newPressed() { onNew?() }
}

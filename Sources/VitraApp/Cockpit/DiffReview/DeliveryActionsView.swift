import AppKit

/// Under an open worker's answer: "Ver mudanças", and beside it how big the
/// change is, which git counts off the main thread when the row opens.
final class DeliveryActionsView: NSStackView {
    var onReview: ((Delivery) -> Void)?

    private let button = NSButton(title: "", target: nil, action: nil)
    private let stat = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private var delivery: Delivery?
    /// Counts the reads, so one that finishes late does not overwrite a newer.
    private var reading = 0

    init() {
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(reviewClicked)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: "Ver mudanças", attributes: [
            .font: CockpitStyle.label, .foregroundColor: CockpitStyle.accent,
        ])
        button.image = NSImage(systemSymbolName: "plus.forwardslash.minus", accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.contentTintColor = CockpitStyle.accent
        button.imagePosition = .imageLeading
        button.toolTip = "Revisar o diff desta entrega e comentar linhas"
        button.setContentHuggingPriority(.required, for: .horizontal)
        stat.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setViews([button, stat], in: .leading)
        spacing = CockpitStyle.Space.md
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the action for `delivery` while the row is open, and counts the
    /// change again each time it opens: a redo may have added to the branch.
    func show(_ delivery: Delivery?, isOpen: Bool) {
        let opening = isOpen && isHidden
        self.delivery = delivery
        isHidden = !(isOpen && delivery != nil)
        guard opening, let delivery else { return }
        reading += 1
        let this = reading
        DispatchQueue.global(qos: .utility).async {
            let text = DeliveryDiff.summary(delivery)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, this == self.reading else { return }
                    self.stat.stringValue = text ?? "já integrada ou descartada"
                }
            }
        }
    }

    @objc private func reviewClicked() {
        if let delivery { onReview?(delivery) }
    }
}

import AppKit

/// The ranking's own header: the "RANKING" title with the "nunca usados"
/// switch at its right, the two choices of slice under it, and one line that
/// counts what the slice holds.
///
/// Laid out like the Escalação and the Resumo above and beside it: a micro
/// caps title on the content inset, the controls in the panel's quiet text,
/// nothing boxed.
final class RankingControls: NSView {
    var onChange: ((RankingOptions) -> Void)?
    private var options = RankingOptions()

    private let grouping = RankingControls.popUp(RankingGrouping.allCases.map(\.title), label: "Agrupar por")
    private let order = RankingControls.popUp(RankingOrder.allCases.map(\.title), label: "Ordenar por")
    private let unused = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let summary = NSTextField.label("", font: CockpitStyle.caption, color: CockpitStyle.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField.label("RANKING", font: CockpitStyle.micro, color: CockpitStyle.text)
        unused.target = self
        unused.action = #selector(changed)
        unused.controlSize = .small
        unused.setContentHuggingPriority(.required, for: .horizontal)
        unused.setAccessibilityLabel("Mostrar os workers nunca usados")
        let top = NSStackView(views: [title, NSView(), unused])
        top.alignment = .centerY
        top.heightAnchor.constraint(equalToConstant: 20).isActive = true

        for popUp in [grouping, order] {
            popUp.target = self
            popUp.action = #selector(changed)
        }
        let choices = NSStackView(views: [
            Self.caption("Agrupar"), grouping, Self.caption("Ordenar"), order, NSView(),
        ])
        choices.alignment = .centerY
        choices.spacing = CockpitStyle.Space.xs
        choices.setCustomSpacing(CockpitStyle.Space.lg, after: grouping)
        choices.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let stack = NSStackView(views: [top, choices, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CockpitStyle.Space.xs
        stack.setCustomSpacing(CockpitStyle.Space.sm, after: top)
        for view in [top, choices, summary] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        addFilling(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `options` and the slice's counts. `unusedCount` is nil while the
    /// catalogue is still being listed.
    func show(_ options: RankingOptions, unusedCount: Int?, summary text: String) {
        self.options = options
        grouping.selectItem(at: RankingGrouping.allCases.firstIndex(of: options.grouping) ?? 0)
        order.selectItem(at: RankingOrder.allCases.firstIndex(of: options.order) ?? 0)
        unused.state = options.showsUnused ? .on : .off
        unused.attributedTitle = NSAttributedString(
            string: "nunca usados" + (unusedCount.map { " (\($0))" } ?? ""),
            attributes: [.font: CockpitStyle.caption, .foregroundColor: CockpitStyle.muted]
        )
        summary.stringValue = text
    }

    @objc private func changed() {
        var next = options
        let grouping = RankingGrouping.allCases[max(self.grouping.indexOfSelectedItem, 0)]
        let order = RankingOrder.allCases[max(self.order.indexOfSelectedItem, 0)]
        next.grouping = grouping
        // A new ordering starts the natural way round, as a click on its head does.
        if order != next.order { next = next.clicking(order) }
        next.showsUnused = unused.state == .on
        options = next
        onChange?(next)
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField.label(text, font: CockpitStyle.caption, color: CockpitStyle.muted)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// A pop-up drawn as text: the choice in the panel's text, a small
    /// chevron, no bezel — a button would be the loudest thing on the panel.
    private static func popUp(_ titles: [String], label: String) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: titles)
        popUp.isBordered = false
        popUp.controlSize = .small
        popUp.font = CockpitStyle.label
        popUp.contentTintColor = CockpitStyle.text
        popUp.setContentHuggingPriority(.required, for: .horizontal)
        popUp.setContentCompressionResistancePriority(.required, for: .horizontal)
        popUp.setAccessibilityLabel(label)
        return popUp
    }
}

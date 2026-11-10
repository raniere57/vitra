import AppKit

/// The strip across the top of the window: one tab per project, a button to
/// open another, and what today has cost.
final class CockpitTabBar: NSView {
    struct Tab: Equatable {
        let name: String
        /// How many workers are running in the project right now.
        let running: Int
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let tabs = NSStackView()
    private let add = NSButton(title: "", target: nil, action: nil)
    private let today = NSTextField.label("hoje", font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let cost = NSTextField.label("$0.00", font: CockpitStyle.meta, color: CockpitStyle.text)
    private var shown: [Tab] = []
    private var selected = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.bar.cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The bar is the window's title bar: dragging its empty part moves the window.
    override var mouseDownCanMoveWindow: Bool { true }

    func show(_ tabs: [Tab], selected: Int) {
        guard tabs != shown || selected != self.selected else { return }
        shown = tabs
        self.selected = selected

        self.tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let view = TabView(tab, isSelected: index == selected)
            view.onClick = { [weak self] in self?.onSelect?(index) }
            view.onClose = { [weak self] in self?.onClose?(index) }
            self.tabs.addArrangedSubview(view)
        }
        self.tabs.addArrangedSubview(add)
    }

    func show(costToday: Double) {
        cost.stringValue = WorkerBoard.money(costToday)
    }

    @objc private func addProject(_ sender: Any?) { onAdd?() }

    private func build() {
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.isBordered = false
        add.contentTintColor = CockpitStyle.muted
        add.target = self
        add.action = #selector(addProject(_:))
        add.setAccessibilityLabel("Abrir projeto")
        add.toolTip = "Abrir projeto"
        add.widthAnchor.constraint(equalToConstant: CockpitStyle.rowHeight).isActive = true
        add.heightAnchor.constraint(equalToConstant: CockpitStyle.rowHeight).isActive = true

        tabs.spacing = CockpitStyle.Space.xs
        let spend = NSStackView(views: [today, cost])
        spend.spacing = CockpitStyle.Space.md
        let rule = NSView.rule(CockpitStyle.line)
        for view in [tabs, spend, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.trafficLightInset),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: spend.leadingAnchor, constant: -CockpitStyle.inset),
            spend.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.inset),
            spend.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// One project's tab: its name, and a lit dot with a count while workers run.
private final class TabView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private let isSelected: Bool
    private var isHovered = false

    init(_ tab: CockpitTabBar.Tab, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField.label(
            tab.name,
            font: CockpitStyle.ui(13, isSelected ? .medium : .regular),
            color: isSelected ? CockpitStyle.text : CockpitStyle.muted
        )
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        var views: [NSView] = [name]
        if tab.running > 0 {
            let dot = NSView.filled(CockpitStyle.accent, cornerRadius: CockpitStyle.Radius.dot)
            dot.widthAnchor.constraint(equalToConstant: 2 * CockpitStyle.Radius.dot).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 2 * CockpitStyle.Radius.dot).isActive = true
            let count = NSTextField.label("\(tab.running)", font: CockpitStyle.meta, color: CockpitStyle.muted)
            views = [dot, name, count]
        }
        let row = NSStackView(views: views)
        row.spacing = CockpitStyle.Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CockpitStyle.rowHeight),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.lg),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.lg),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])

        let close = NSMenuItem(title: "Fechar projeto", action: #selector(closeProject(_:)), keyEquivalent: "")
        close.target = self
        menu = NSMenu()
        menu?.addItem(close)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let running = tab.running > 0 ? ", \(tab.running) rodando" : ""
        setAccessibilityLabel(tab.name + running)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A click on a tab is a click, never the start of a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closeProject(_ sender: Any?) { onClose?() }

    private func paint() {
        let fill = isSelected ? CockpitStyle.tab : (isHovered ? CockpitStyle.raised : .clear)
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = CockpitStyle.controlLine.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        paint()
    }
}

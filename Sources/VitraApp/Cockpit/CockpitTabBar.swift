import AppKit

/// The strip across the top of the window: one tab per project, a button to
/// open another, and what today has cost.
final class CockpitTabBar: NSView {
    struct Tab: Equatable {
        let name: String
        /// How many workers are running in the project right now.
        let running: Int
        /// The maestro is waiting on the user: the dot turns amber and pulses.
        var callsForYou = false
        /// Prompts in the project's Fila: "+3" after the worker count, the
        /// first thing the bar gives up when tight.
        var queued = 0
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let tabs = NSStackView()
    private let add = NSButton(title: "", target: nil, action: nil)
    private let today = NSTextField.label("hoje", font: CockpitStyle.meta, color: CockpitStyle.muted)
    private let cost = NSTextField.label("$0.00", font: CockpitStyle.meta, color: CockpitStyle.text)
    private let chipRow = NSStackView()
    private var shown: [Tab] = []
    private var shownChips: [ProviderChip] = []
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

    /// Provider facts worth a glance, left of the day's cost; none when all is well.
    func show(chips: [ProviderChip]) {
        guard chips != shownChips else { return }
        shownChips = chips
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.map(ChipView.init).forEach(chipRow.addArrangedSubview)
        chipRow.isHidden = chips.isEmpty
        needsLayout = true
    }

    /// The chips are the first thing the bar gives up: the tabs and the day's
    /// cost never clip for them. Decided from what each piece needs, not from
    /// how the layout came out, so it cannot flap.
    ///
    /// The Fila counts on the tabs go before even the chips: they are the
    /// least of what a tab says.
    override func layout() {
        super.layout()
        let tabViews = tabs.arrangedSubviews.compactMap { $0 as? TabView }
        let queueWidth = tabViews.map(\.queueWidth).reduce(0, +)
        let shownQueue = tabViews.contains { $0.showsQueue } ? queueWidth : 0
        let tabsBare = tabs.fittingSize.width - shownQueue
        let spend = today.fittingSize.width + CockpitStyle.Space.md + cost.fittingSize.width + CockpitStyle.inset
        let chips = shownChips.isEmpty ? 0 : chipRow.fittingSize.width + CockpitStyle.Space.lg
        let showsQueue = CockpitStyle.trafficLightInset + tabsBare + queueWidth + CockpitStyle.inset + chips + spend <= bounds.width
        tabViews.forEach { $0.showsQueue = showsQueue }
        let needed = CockpitStyle.trafficLightInset + tabsBare + (showsQueue ? queueWidth : 0) + CockpitStyle.inset + chips + spend
        let hides = shownChips.isEmpty || needed > bounds.width
        if chipRow.isHidden != hides { chipRow.isHidden = hides }
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
        chipRow.spacing = CockpitStyle.Space.sm
        chipRow.isHidden = true
        let spend = NSStackView(views: [chipRow, today, cost])
        spend.spacing = CockpitStyle.Space.md
        spend.setCustomSpacing(CockpitStyle.Space.lg, after: chipRow)
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
    private var pulsingDot: NSView?

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
        if tab.running > 0 || tab.callsForYou {
            // Amber both for "workers running" and "waiting for you"; only the
            // second pulses.
            let dot = NSView.filled(CockpitStyle.accent, cornerRadius: CockpitStyle.Radius.dot)
            dot.widthAnchor.constraint(equalToConstant: 2 * CockpitStyle.Radius.dot).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 2 * CockpitStyle.Radius.dot).isActive = true
            views = [dot, name]
            if tab.running > 0 {
                views.append(NSTextField.label("\(tab.running)", font: CockpitStyle.meta, color: CockpitStyle.muted))
            }
            if tab.callsForYou { pulsingDot = dot }
        }
        if tab.queued > 0 {
            queueLabel.stringValue = "+\(tab.queued)"
            queueLabel.toolTip = "\(tab.queued) na fila do maestro"
            queueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(queueLabel)
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
        let waiting = tab.callsForYou ? ", aguardando você" : ""
        let queued = tab.queued > 0 ? ", \(tab.queued) na fila" : ""
        setAccessibilityLabel(tab.name + running + waiting + queued)
        hasQueue = tab.queued > 0
        paint()
    }

    private let queueLabel = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
    private var hasQueue = false

    /// What the "+3" takes with its gap; nothing for a tab without a queue.
    var queueWidth: CGFloat {
        hasQueue ? queueLabel.fittingSize.width + CockpitStyle.Space.md : 0
    }

    var showsQueue: Bool {
        get { hasQueue && !queueLabel.isHidden }
        set {
            let hidden = !(newValue && hasQueue)
            if queueLabel.isHidden != hidden { queueLabel.isHidden = hidden }
        }
    }

    // MARK: Pulse

    private static let pulseKey = "attention-pulse"
    private static let pulseDuration: CFTimeInterval = 0.9
    private static let pulseLow: Float = 0.25

    /// Pulses while the window can be seen and Reduce Motion is off; otherwise
    /// the dot is simply solid amber.
    private func updatePulse() {
        guard let layer = pulsingDot?.layer else { return }
        let isVisible = window?.occlusionState.contains(.visible) ?? false
        guard isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = Self.pulseLow
        pulse.duration = Self.pulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard pulsingDot != nil else { return }
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(pulseConditionsChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(pulseConditionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        updatePulse()
    }

    @objc private func pulseConditionsChanged(_ notification: Notification) { updatePulse() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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

/// A provider fact on a small plate: amber when notable, red when nearly out,
/// muted for a CLI that has hit its limit.
private final class ChipView: NSView {
    init(_ chip: ProviderChip) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = CockpitStyle.Radius.control
        layer?.borderWidth = 1
        layer?.backgroundColor = CockpitStyle.raised.cgColor
        let color: NSColor
        switch chip.level {
        case .muted: color = CockpitStyle.muted
        case .warm: color = CockpitStyle.accent
        case .hot: color = CockpitStyle.dangerText
        }
        layer?.borderColor = (chip.level == .muted ? CockpitStyle.raisedLine : color.withAlphaComponent(0.5)).cgColor
        let label = NSTextField.label(chip.text, font: CockpitStyle.meta, color: color)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.md),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.md),
            label.topAnchor.constraint(equalTo: topAnchor, constant: CockpitStyle.Space.xs),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CockpitStyle.Space.xs),
        ])
        toolTip = chip.tooltip
        setAccessibilityElement(true)
        setAccessibilityLabel(chip.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { true }
}

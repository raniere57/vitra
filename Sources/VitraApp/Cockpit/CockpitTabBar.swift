import AppKit

/// The strip across the top of the window: one tab per project, a button to
/// open another, and what today has cost.
final class CockpitTabBar: NSView {
    struct Tab: Equatable {
        let name: String
        /// How many workers are running in the project right now.
        let running: Int
        /// The maestro stopped for a permission: the dot pulses amber until
        /// it is answered.
        var callsForYou = false
        /// The maestro is in the middle of a turn: a steady amber dot, the
        /// same as while workers run.
        var maestroWorking = false
        /// The maestro finished a turn the user has not looked at yet: the
        /// dot pulses green, and goes out once the project is opened.
        var finishedUnseen = false
        /// Prompts in the project's Fila: "+3" after the worker count, the
        /// first thing the bar gives up when tight.
        var queued = 0
        /// Put to sleep: nothing of it runs until the tab is clicked.
        var isAsleep = false
        /// The project's folder, for the tooltip.
        var path = ""
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    /// A project closed lately, picked from the "+": its folder.
    var onReopen: ((String) -> Void)?
    var onSleep: ((Int) -> Void)?
    var onReveal: ((Int) -> Void)?
    /// A tab dragged to another place: from which index to which.
    var onMove: ((Int, Int) -> Void)?
    private var recent: [String] = []
    /// Where a dragged tab would land.
    private let dropMark = NSView.filled(CockpitStyle.accent, cornerRadius: 1)

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
            let view = TabView(tab, isSelected: index == selected, number: index + 1)
            view.onDrag = { [weak self] point in self?.dragged(index, to: point) }
            view.onDrop = { [weak self] point in self?.dropped(index, at: point) }
            view.onClick = { [weak self] in self?.onSelect?(index) }
            view.onClose = { [weak self] in self?.onClose?(index) }
            view.onSleep = { [weak self] in self?.onSleep?(index) }
            view.onReveal = { [weak self] in self?.onReveal?(index) }
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

    // MARK: Reordering

    /// Where the tab at `index` lands when let go at `point` (window
    /// coordinates): before the first tab whose middle is past the pointer.
    private func slot(for index: Int, at point: NSPoint) -> Int {
        let x = tabs.convert(point, from: nil).x
        let others = tabs.arrangedSubviews.compactMap { $0 as? TabView }.enumerated().filter { $0.offset != index }
        return others.filter { $0.element.frame.midX < x }.count
    }

    private func dragged(_ index: Int, to point: NSPoint) {
        let views = tabs.arrangedSubviews.compactMap { $0 as? TabView }
        let target = slot(for: index, at: point)
        let others = views.enumerated().filter { $0.offset != index }.map(\.element)
        guard !others.isEmpty else { return }
        let edge = target < others.count ? others[target].frame.minX - CockpitStyle.Space.xs / 2 : others[others.count - 1].frame.maxX + CockpitStyle.Space.xs / 2
        let x = convert(NSPoint(x: edge, y: 0), from: tabs).x
        dropMark.frame = NSRect(x: x - 1, y: (bounds.height - 18) / 2, width: 2, height: 18)
        dropMark.isHidden = target == index
    }

    private func dropped(_ index: Int, at point: NSPoint) {
        dropMark.isHidden = true
        let target = slot(for: index, at: point)
        if target != index { onMove?(index, target) }
    }

    /// The folders of the projects closed lately, newest first.
    func show(recent: [String]) { self.recent = recent }

    /// With projects closed lately, the "+" offers them back before the
    /// folder picker; with none it goes straight to the picker.
    @objc private func addProject(_ sender: Any?) {
        guard !recent.isEmpty else {
            onAdd?()
            return
        }
        let menu = NSMenu()
        let header = NSMenuItem(title: "Reabrir de onde parou", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for path in recent {
            let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent, action: #selector(reopen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.toolTip = (path as NSString).abbreviatingWithTildeInPath
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pick = NSMenuItem(title: "Escolher pasta…", action: #selector(pickFolder(_:)), keyEquivalent: "")
        pick.target = self
        pick.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(pick)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.maxY + CockpitStyle.Space.xs), in: add)
    }

    @objc private func reopen(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { onReopen?(path) }
    }

    @objc private func pickFolder(_ sender: Any?) { onAdd?() }

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
        dropMark.isHidden = true
        dropMark.translatesAutoresizingMaskIntoConstraints = true
        addSubview(dropMark)
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onSleep: (() -> Void)?
    var onReveal: (() -> Void)?
    /// The tab is being dragged, and where the pointer is in the window.
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    private var pressedAt: NSPoint?
    private var isDragging = false
    /// How far the pointer travels before a press is a drag, not a click.
    private static let dragSlop: CGFloat = 6
    /// Room kept at the selected tab's end for its x, so the x never sits on
    /// the name and showing it never moves anything.
    private static let closeSlot: CGFloat = 18

    private let isSelected: Bool
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var isHovered = false
    private var pulsingDot: NSView?

    init(_ tab: CockpitTabBar.Tab, isSelected: Bool, number: Int = 0) {
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
        if tab.isAsleep {
            // Asleep says so before anything else: a moon, and the name faded.
            name.textColor = CockpitStyle.muted.withAlphaComponent(0.6)
            let moon = NSImageView()
            moon.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular))
            moon.contentTintColor = CockpitStyle.muted.withAlphaComponent(0.6)
            views = [moon, name]
        } else if tab.running > 0 || tab.callsForYou || tab.maestroWorking || tab.finishedUnseen {
            // One meaning per look: steady amber is work going on; pulsing
            // amber is a permission asked; pulsing green is a turn that ended
            // and has not been seen. A project that is idle and seen has no dot.
            let isDone = tab.finishedUnseen && !tab.callsForYou
            let dot = NSView.filled(isDone ? CockpitStyle.success : CockpitStyle.accent, cornerRadius: CockpitStyle.Radius.dot)
            dot.widthAnchor.constraint(equalToConstant: 2 * CockpitStyle.Radius.dot).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 2 * CockpitStyle.Radius.dot).isActive = true
            views = [dot, name]
            if tab.running > 0 {
                views.append(NSTextField.label("\(tab.running)", font: CockpitStyle.meta, color: CockpitStyle.muted))
            }
            if tab.callsForYou || tab.finishedUnseen { pulsingDot = dot }
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
            row.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -(CockpitStyle.Space.lg + (isSelected ? Self.closeSlot : 0))
            ),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])

        // Only the tab in front has an x, in room of its own: a click meant to
        // open another project can never land on a close.
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = CockpitStyle.muted
        closeButton.target = self
        closeButton.action = #selector(closeProject(_:))
        closeButton.toolTip = "Fechar projeto"
        closeButton.setAccessibilityLabel("Fechar \(tab.name)")
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 8
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.md),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        menu = NSMenu()
        let items: [(String, String, Selector)] = [
            (tab.isAsleep ? "Retomar projeto" : "Suspender projeto", tab.isAsleep ? "play" : "moon", #selector(sleepProject(_:))),
            ("Mostrar no Finder", "folder", #selector(revealProject(_:))),
            ("Fechar projeto", "xmark", #selector(closeProject(_:))),
        ]
        for (index, (title, symbol, action)) in items.enumerated() {
            if index == items.count - 1 { menu?.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu?.addItem(item)
        }
        let folder = (tab.path as NSString).abbreviatingWithTildeInPath
        let chord = (1...9).contains(number) ? " · ⌘\(number)" : ""
        toolTip = (tab.isAsleep ? "\(folder) · suspenso" : folder) + chord

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let running = tab.running > 0 ? ", \(tab.running) rodando" : ""
        let asleep = tab.isAsleep ? ", suspenso" : ""
        let waiting = tab.callsForYou ? ", pede permissão" : (tab.finishedUnseen ? ", terminou e aguarda você" : (tab.maestroWorking ? ", trabalhando" : ""))
        let queued = tab.queued > 0 ? ", \(tab.queued) na fila" : ""
        setAccessibilityLabel(tab.name + asleep + running + waiting + queued)
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
    @objc private func sleepProject(_ sender: Any?) { onSleep?() }
    @objc private func revealProject(_ sender: Any?) { onReveal?() }

    private func paint() {
        let fill = isSelected ? CockpitStyle.tab : (isHovered ? CockpitStyle.raised : .clear)
        layer?.backgroundColor = fill.cgColor
        // The x sits on the tab's own colour, so the name ends under it cleanly.
        closeButton.isHidden = !isSelected
        closeButton.alphaValue = isHovered ? 1 : 0.45
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = CockpitStyle.controlLine.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        if !isDragging, abs(event.locationInWindow.x - pressedAt.x) > Self.dragSlop {
            isDragging = true
            alphaValue = 0.5
        }
        if isDragging { onDrag?(event.locationInWindow) }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedAt = nil
            isDragging = false
            alphaValue = 1
        }
        if isDragging {
            onDrop?(event.locationInWindow)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    /// The middle button closes, as in a browser.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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

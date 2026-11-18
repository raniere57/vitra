import AppKit

/// The left side of the window: each project a group, its sessions under it,
/// and above them the sessions that wait on the user.
///
/// A session is a tab of the cockpit: its own maestro and conversation on the
/// project's folder. Several on one project are several pieces of work at
/// once, and the project's diary keeps them aware of each other.
final class ProjectSidebar: NSView {
    static let width: CGFloat = 224

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onSleep: ((Int) -> Void)?
    var onReveal: ((Int) -> Void)?
    /// Another session on the folder of the tab at this index.
    var onNewSession: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onReopen: ((String) -> Void)?
    /// The one-off conversation, at the foot of the list.
    var onScratch: (() -> Void)?

    /// The one-off conversation is on screen, not a project.
    var isScratchSelected = false {
        didSet {
            guard isScratchSelected != oldValue else { return }
            scratch.isSelected = isScratchSelected
            // The project's row stops looking selected while it is not shown.
            render()
        }
    }
    /// The clock the ages are read against.
    var now: () -> Date = Date.init
    private let scratch = ScratchRow()

    private let list = NSStackView()
    /// "PARA VOCÊ": the sessions that stopped for the user, out of their groups.
    private let calls = NSStackView()
    private let add = NSButton(title: "", target: nil, action: nil)
    private var shown: [CockpitTabBar.Tab] = []
    private var selected = -1
    private var recent: [(key: String, name: String, path: String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.bar.cgColor
        build()
        // "8m" becomes "9m" with nothing else changing.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The projects in the order of their first tab, each with its tabs.
    static func groups(_ tabs: [CockpitTabBar.Tab]) -> [(path: String, indices: [Int])] {
        var groups: [(path: String, indices: [Int])] = []
        for (index, tab) in tabs.enumerated() {
            if let at = groups.firstIndex(where: { $0.path == tab.path }) {
                groups[at].indices.append(index)
            } else {
                groups.append((tab.path, [index]))
            }
        }
        return groups
    }

    /// A session's name in the list: the conversation's when claude named
    /// it, else the first one is "principal" and the others are numbered.
    static func sessionTitle(_ tab: CockpitTabBar.Tab) -> String {
        if let session = tab.session, !session.isEmpty { return session }
        return tab.slot <= 1 ? "principal" : "sessão \(tab.slot)"
    }

    func show(_ tabs: [CockpitTabBar.Tab], selected: Int) {
        guard tabs != shown || selected != self.selected else { return }
        shown = tabs
        self.selected = selected
        render()
    }

    private func render() {
        let tabs = shown
        let now = now()
        let statuses = tabs.map(SessionStatus.init)
        func row(_ index: Int, title: String, message: String? = nil) -> SessionRow {
            let row = SessionRow(
                tabs[index], status: statuses[index], age: SessionStatus.age(since: tabs[index].since, now: now),
                title: title, message: message, isSelected: index == selected && !isScratchSelected, number: index + 1
            )
            row.onClick = { [weak self] in self?.onSelect?(index) }
            row.onClose = { [weak self] in self?.onClose?(index) }
            row.onSleep = { [weak self] in self?.onSleep?(index) }
            row.onReveal = { [weak self] in self?.onReveal?(index) }
            return row
        }

        calls.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let forYou = tabs.indices.filter { statuses[$0].isForYou }
        if !forYou.isEmpty {
            let title = NSTextField.label("PARA VOCÊ", font: CockpitStyle.micro, color: CockpitStyle.accent)
            let head = NSStackView(views: [title])
            head.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.md, left: CockpitStyle.Space.md, bottom: CockpitStyle.Space.xs, right: 0)
            calls.addArrangedSubview(head)
            for index in forYou {
                let project = URL(fileURLWithPath: tabs[index].path).lastPathComponent
                let row = row(index, title: "\(project) · \(Self.sessionTitle(tabs[index]))", message: tabs[index].message)
                calls.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: calls.widthAnchor).isActive = true
            }
        }

        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in Self.groups(tabs) {
            let first = group.indices[0]
            let allAsleep = group.indices.allSatisfy { tabs[$0].isAsleep }
            let header = GroupHeader(name: URL(fileURLWithPath: group.path).lastPathComponent, path: group.path, isAsleep: allAsleep)
            header.onAdd = { [weak self] in self?.onNewSession?(first) }
            header.onReveal = { [weak self] in self?.onReveal?(first) }
            list.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            // The project keeps its place while its sessions are up with the user.
            for index in group.indices where !statuses[index].isForYou {
                let row = row(index, title: Self.sessionTitle(tabs[index]))
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            list.setCustomSpacing(CockpitStyle.Space.lg, after: list.arrangedSubviews.last!)
        }
    }

    func show(recent: [(key: String, name: String, path: String)]) { self.recent = recent }

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
        for (key, name, path) in recent {
            let item = NSMenuItem(title: name, action: #selector(reopen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
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
        if let key = sender.representedObject as? String { onReopen?(key) }
    }

    @objc private func pickFolder(_ sender: Any?) { onAdd?() }

    private func build() {
        let title = NSTextField.label("PROJETOS", font: CockpitStyle.micro, color: CockpitStyle.muted)
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.isBordered = false
        add.contentTintColor = CockpitStyle.muted
        add.target = self
        add.action = #selector(addProject(_:))
        add.toolTip = "Abrir projeto"
        add.setAccessibilityLabel("Abrir projeto")
        let top = NSStackView(views: [title, NSView(), add])
        top.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.Space.md)

        calls.orientation = .vertical
        calls.alignment = .leading
        calls.spacing = 0
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        let rule = NSView.filled(CockpitStyle.line, cornerRadius: 0)
        scratch.onClick = { [weak self] in self?.onScratch?() }
        let footRule = NSView.filled(CockpitStyle.softLine, cornerRadius: 0)
        for view in [calls, top, scroll, rule, footRule, scratch] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            calls.topAnchor.constraint(equalTo: topAnchor),
            calls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.sm),
            calls.trailingAnchor.constraint(equalTo: rule.leadingAnchor, constant: -CockpitStyle.Space.sm),
            top.topAnchor.constraint(equalTo: calls.bottomAnchor, constant: CockpitStyle.Space.md),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: CockpitStyle.rowHeight),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: CockpitStyle.Space.sm),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: rule.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footRule.topAnchor),
            footRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            footRule.trailingAnchor.constraint(equalTo: rule.leadingAnchor),
            footRule.heightAnchor.constraint(equalToConstant: 1),
            footRule.bottomAnchor.constraint(equalTo: scratch.topAnchor, constant: -CockpitStyle.Space.sm),
            scratch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.sm),
            scratch.trailingAnchor.constraint(equalTo: rule.leadingAnchor, constant: -CockpitStyle.Space.sm),
            scratch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CockpitStyle.Space.sm),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: CockpitStyle.Space.sm),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -CockpitStyle.Space.sm),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.widthAnchor.constraint(equalToConstant: 1),
        ])
    }
}

/// A project's name, with a "+" for another session on it.
private final class GroupHeader: NSView {
    var onAdd: (() -> Void)?
    var onReveal: (() -> Void)?

    init(name: String, path: String, isAsleep: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField.label(name, font: CockpitStyle.ui(12, .semibold), color: isAsleep ? CockpitStyle.muted : CockpitStyle.text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let add = NSButton(title: "", target: self, action: #selector(addSession(_:)))
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        add.isBordered = false
        add.contentTintColor = CockpitStyle.muted
        add.toolTip = "Nova sessão em \(name)"
        add.setAccessibilityLabel("Nova sessão em \(name)")
        let row = NSStackView(views: [label, NSView(), add])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.sm),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = (path as NSString).abbreviatingWithTildeInPath
        menu = NSMenu()
        let new = NSMenuItem(title: "Nova sessão", action: #selector(addSession(_:)), keyEquivalent: "")
        new.target = self
        new.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let reveal = NSMenuItem(title: "Mostrar no Finder", action: #selector(reveal(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu?.addItem(new)
        menu?.addItem(reveal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func addSession(_ sender: Any?) { onAdd?() }
    @objc private func reveal(_ sender: Any?) { onReveal?() }
}

/// One session: its state mark, its name, what it is doing and for how long.
private final class SessionRow: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onSleep: (() -> Void)?
    var onReveal: (() -> Void)?

    private let isSelected: Bool
    private var isHovered = false

    init(_ tab: CockpitTabBar.Tab, status: SessionStatus, age: String, title: String, message: String?, isSelected: Bool, number: Int) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField.label(
            title,
            font: CockpitStyle.ui(13, isSelected ? .medium : .regular),
            color: tab.isAsleep ? CockpitStyle.muted.withAlphaComponent(0.6) : (isSelected ? CockpitStyle.text : CockpitStyle.muted)
        )
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A mark of its own for each state: a hand asks, a check is a turn
        // not seen yet, a steady dot is the maestro at work, a half disc its
        // workers going on without it, a moon asleep, nothing idle and seen.
        func symbol(_ name: String, _ color: NSColor) -> NSImageView {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
            image.contentTintColor = color
            return image
        }
        let tint: NSColor
        let mark: NSView
        switch status {
        case .asleep:
            tint = CockpitStyle.muted.withAlphaComponent(0.6)
            mark = symbol("moon.fill", tint)
        case .permission:
            tint = CockpitStyle.accent
            mark = symbol("hand.raised.fill", tint)
        case .finished:
            tint = CockpitStyle.success
            mark = symbol("checkmark", tint)
        case .working:
            tint = CockpitStyle.muted
            mark = NSView.filled(CockpitStyle.accent, cornerRadius: CockpitStyle.Radius.dot)
        case .workers:
            tint = CockpitStyle.muted
            mark = symbol("circle.lefthalf.filled", CockpitStyle.accent)
        case .idle:
            tint = CockpitStyle.muted.withAlphaComponent(0.6)
            mark = NSView()
        }
        if status.isForYou, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            mark.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            mark.layer?.add(pulse, forKey: "attention-pulse")
        }
        let markBox = NSView()
        markBox.translatesAutoresizingMaskIntoConstraints = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        markBox.addSubview(mark)
        let side: CGFloat = status == .working ? 2 * CockpitStyle.Radius.dot : 11
        NSLayoutConstraint.activate([
            markBox.widthAnchor.constraint(equalToConstant: 12),
            markBox.heightAnchor.constraint(equalToConstant: 12),
            mark.widthAnchor.constraint(equalToConstant: side),
            mark.heightAnchor.constraint(equalToConstant: side),
            mark.centerXAnchor.constraint(equalTo: markBox.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: markBox.centerYAnchor),
        ])

        // Up with the user the row's place says why it is there; its age is what is left to say.
        var words = message == nil && !status.isForYou ? [status.label] : []
        if !age.isEmpty { words.append(age) }
        if tab.running > 0, status != .workers(tab.running) { words.append("· \(tab.running)") }
        if tab.queued > 0 { words.append("+\(tab.queued)") }
        let state = NSTextField.label(words.joined(separator: " "), font: CockpitStyle.meta, color: tint)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [markBox, name, NSView(), state])
        row.spacing = CockpitStyle.Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.lg),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.md),
            row.centerYAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
        // What the maestro asks, under its name.
        if let message, !message.isEmpty {
            let asked = NSTextField.label(message, font: CockpitStyle.meta, color: CockpitStyle.muted)
            asked.lineBreakMode = .byTruncatingTail
            asked.translatesAutoresizingMaskIntoConstraints = false
            addSubview(asked)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 44),
                asked.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                asked.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.Space.md),
                asked.topAnchor.constraint(equalTo: topAnchor, constant: 25),
            ])
        } else {
            heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        menu = NSMenu()
        let items: [(String, String, Selector)] = [
            (tab.isAsleep ? "Retomar sessão" : "Suspender sessão", tab.isAsleep ? "play" : "moon", #selector(sleepSession(_:))),
            ("Mostrar no Finder", "folder", #selector(revealSession(_:))),
            ("Fechar sessão", "xmark", #selector(closeSession(_:))),
        ]
        for (index, (title, symbol, action)) in items.enumerated() {
            if index == items.count - 1 { menu?.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu?.addItem(item)
        }
        let chord = (1...9).contains(number) ? "⌘\(number)" : ""
        toolTip = [title, status == .idle ? "" : status.label, message ?? "", chord].filter { !$0.isEmpty }.joined(separator: " · ")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(([tab.name + " " + title] + (status == .idle ? [] : [status.label]) + (message.map { [$0] } ?? [])).joined(separator: ", "))
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; paint() }
    override func mouseExited(with event: NSEvent) { isHovered = false; paint() }
    // On the press, like a sidebar: the list is rebuilt whenever a session's
    // state changes, and a row replaced between press and release would
    // never see the release.
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func paint() {
        layer?.backgroundColor = isSelected ? CockpitStyle.tab.cgColor : (isHovered ? CockpitStyle.raised.cgColor : NSColor.clear.cgColor)
    }

    @objc private func sleepSession(_ sender: Any?) { onSleep?() }
    @objc private func revealSession(_ sender: Any?) { onReveal?() }
    @objc private func closeSession(_ sender: Any?) { onClose?() }
}

/// "Conversa avulsa": a conversation outside every project, back where it stopped after a relaunch.
private final class ScratchRow: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    var onClick: (() -> Void)?
    var isSelected = false { didSet { paint() } }
    private var isHovered = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        icon.contentTintColor = CockpitStyle.muted
        let name = NSTextField.label("Conversa avulsa", font: CockpitStyle.ui(13, .regular), color: CockpitStyle.muted)
        let row = NSStackView(views: [icon, name])
        row.spacing = CockpitStyle.Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.Space.md),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Conversa fora dos projetos. Continua de onde parou; /clear começa outra."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Conversa avulsa")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; paint() }
    override func mouseExited(with event: NSEvent) { isHovered = false; paint() }
    // On the press, like a sidebar: the list is rebuilt whenever a session's
    // state changes, and a row replaced between press and release would
    // never see the release.
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func paint() {
        layer?.backgroundColor = isSelected ? CockpitStyle.tab.cgColor : (isHovered ? CockpitStyle.raised.cgColor : NSColor.clear.cgColor)
    }
}

import AppKit

/// The list "/" and "@" open over the composer: a borderless panel above the
/// field, driven from the text view's keys (↑↓ move, ⇥ or ⏎ take, ⎋ closes),
/// so the keyboard never leaves the text.
@MainActor
final class CompletionPopup {
    static let rowHeight: CGFloat = 26
    var onChoose: ((ComposerCompletion) -> Void)?

    private(set) var items: [ComposerCompletion] = []
    private(set) var selected = 0
    private var panel: NSPanel?
    private let list = CompletionList()

    var isShown: Bool { panel?.isVisible == true && !items.isEmpty }

    /// Shows `items` with their bottom edge on `anchor` (screen coordinates),
    /// as wide as it; hides when there is nothing to show.
    func show(_ items: [ComposerCompletion], above anchor: NSRect, in window: NSWindow) {
        guard !items.isEmpty else { return hide() }
        if items != self.items { selected = 0 }
        self.items = items
        let panel = self.panel ?? makePanel()
        let height = CGFloat(items.count) * Self.rowHeight + 8
        panel.setFrame(NSRect(x: anchor.minX, y: anchor.maxY + 4, width: anchor.width, height: height), display: false)
        list.frame = NSRect(origin: .zero, size: panel.frame.size)
        list.show(items, selected: selected)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        items = []
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + by + items.count) % items.count
        list.show(items, selected: selected)
    }

    func chooseSelected() {
        guard items.indices.contains(selected) else { return }
        onChoose?(items[selected])
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = list
        list.onClick = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.selected = index
            self.chooseSelected()
        }
        self.panel = panel
        return panel
    }
}

/// The rows, drawn: what goes in on the left, what it is on the right.
private final class CompletionList: NSView {
    var onClick: ((Int) -> Void)?
    private var items: [ComposerCompletion] = []
    private var selected = 0

    override var isFlipped: Bool { true }

    func show(_ items: [ComposerCompletion], selected: Int) {
        self.items = items
        self.selected = selected
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        CockpitStyle.raised.setFill()
        shape.fill()
        CockpitStyle.controlLine.setStroke()
        shape.stroke()
        for (index, item) in items.enumerated() {
            let row = NSRect(x: 4, y: 4 + CGFloat(index) * CompletionPopup.rowHeight, width: bounds.width - 8, height: CompletionPopup.rowHeight)
            if index == selected {
                CockpitStyle.tab.setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            }
            let name = NSAttributedString(string: item.insert, attributes: [
                .font: CockpitStyle.mono(12.5, index == selected ? .medium : .regular),
                .foregroundColor: index == selected ? CockpitStyle.accent : CockpitStyle.text,
            ])
            let nameWidth = min(name.size().width, row.width * 0.6)
            name.draw(with: NSRect(x: row.minX + 8, y: row.minY + 5, width: nameWidth, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            guard !item.detail.isEmpty else { continue }
            let detail = NSAttributedString(string: item.detail, attributes: [
                .font: CockpitStyle.ui(12), .foregroundColor: CockpitStyle.muted,
            ])
            let left = row.minX + 8 + nameWidth + 14
            detail.draw(with: NSRect(x: left, y: row.minY + 6, width: max(row.maxX - 8 - left, 0), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onClick?(Int((point.y - 4) / CompletionPopup.rowHeight))
    }
}

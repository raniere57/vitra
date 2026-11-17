import AppKit

/// ⌘/: every chord of the cockpit on one compact sheet, in two columns, read
/// from the same table the menu bar is built from.
enum ShortcutsSheet {
    private static let columnWidth: CGFloat = 280

    /// The sheet's window, ready for `beginSheet`. ⎋ and ⏎ close it.
    @MainActor static func makeWindow() -> NSWindow {
        let window = SheetWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CockpitStyle.ground
        let content = makeView { [weak window] in
            guard let window else { return }
            window.sheetParent?.endSheet(window)
        }
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    /// The sheet's content; `close` is the button's.
    @MainActor static func makeView(close: @escaping () -> Void) -> NSView {
        let title = NSTextField.label("Atalhos de teclado", font: CockpitStyle.display, color: CockpitStyle.text)
        let (left, right) = Shortcut.sheetColumns(Shortcut.sheetSections(from: Shortcut.table))
        let columns = NSStackView(views: [column(left), column(right)])
        columns.alignment = .top
        columns.spacing = 40

        let done = CloseButton(title: "Fechar", action: close)
        let footer = NSStackView(views: [
            NSTextField.label("Também no menu, ao lado de cada comando.", font: CockpitStyle.caption, color: CockpitStyle.muted),
            NSView(),
            done,
        ])

        let stack = NSStackView(views: [title, columns, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CockpitStyle.Space.xxl
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: CockpitStyle.Space.xxl, right: 32)
        footer.widthAnchor.constraint(equalTo: columns.widthAnchor).isActive = true

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = CockpitStyle.ground.cgColor
        view.addFilling(stack)
        return view
    }

    private static func column(_ sections: [Shortcut.SheetSection]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (index, section) in sections.enumerated() {
            let heading = NSTextField.label(section.title.uppercased(), font: CockpitStyle.micro, color: CockpitStyle.muted)
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(CockpitStyle.Space.sm, after: heading)
            for row in section.rows {
                let line = Self.row(row)
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
            }
            if index < sections.count - 1, let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(CockpitStyle.Space.xl, after: last)
            }
        }
        return stack
    }

    /// What it does on the left, the chord flush right — the way the menu
    /// itself sets them, so the eye already knows where to look. In the
    /// system face, which draws ⌃⌥⇧⌘ as the menu does.
    private static func row(_ row: Shortcut.SheetRow) -> NSView {
        let keys = NSTextField.label(row.keys, font: CockpitStyle.ui(13, .medium), color: CockpitStyle.text)
        keys.alignment = .right
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        keys.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField.label(row.title, font: CockpitStyle.body, color: CockpitStyle.muted)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [title, keys])
        line.distribution = .fill
        line.spacing = CockpitStyle.Space.lg
        line.heightAnchor.constraint(equalToConstant: 24).isActive = true
        line.setAccessibilityElement(true)
        line.setAccessibilityRole(.staticText)
        line.setAccessibilityLabel("\(row.title): \(row.keys)")
        return line
    }
}

/// A sheet that closes on Esc, as sheets do.
private final class SheetWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        sheetParent?.endSheet(self)
    }
}

private final class CloseButton: NSButton {
    private let onClose: () -> Void

    init(title: String, action: @escaping () -> Void) {
        onClose = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        keyEquivalent = "\r"
        target = self
        self.action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed() { onClose() }
}

import AppKit
import VitraCore

/// What the maestro waits on, answered from Leitura: the menu its terminal
/// has up — a permission, a question, the review before answers go — drawn
/// as buttons, each the option's digit pressed there. When the screen shows
/// no menu it can read, the plain "pede uma resposta no terminal" and the
/// way there.
final class PermissionBanner: NSView {
    var onGo: (() -> Void)?
    /// The option's digit, pressed in the terminal.
    var onChoose: ((TerminalMenu.Option) -> Void)?
    /// Tab: on from a multiple-choice question.
    var onNext: (() -> Void)?

    private static let plain = "O maestro pede uma resposta no terminal"
    private let icon = NSImageView()
    private let label = NSTextField.label(PermissionBanner.plain, font: ReadingStyle.smallMedium, color: ReadingStyle.text)
    private let button = NSButton()
    private let options = NSStackView()
    private let hint = NSTextField.label(font: CockpitStyle.caption, color: ReadingStyle.quiet)
    private lazy var collapsed = heightAnchor.constraint(equalToConstant: 0)
    private(set) var asked: TerminalMenu?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x2A / 255, green: 0x22 / 255, blue: 0x16 / 255, alpha: 1).cgColor
        layer?.masksToBounds = true
        let rule = NSView.rule(CockpitStyle.accent.withAlphaComponent(0.35))
        icon.image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        icon.contentTintColor = CockpitStyle.accent
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.title = "Ir para o terminal"
        button.keyEquivalent = ""
        button.target = self
        button.action = #selector(go)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 5
        for view in [rule, icon, label, button, options, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = CockpitStyle.inset
        // Below "required": hidden, the height is nought and these give way.
        let bottom = hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        bottom.priority = .defaultHigh
        let top = label.topAnchor.constraint(equalTo: topAnchor, constant: 14)
        top.priority = .defaultHigh
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 4),
            icon.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -4),
            top,
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            button.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -4),
            options.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            options.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            hint.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            bottom,
        ])
        setAccessibilityRole(.group)
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHidden: Bool {
        didSet { collapsed.isActive = isHidden }
    }

    /// The menu to answer, or nil for the plain way to the terminal.
    func show(_ menu: TerminalMenu?) {
        guard menu != asked || options.arrangedSubviews.isEmpty && menu != nil else { return }
        asked = menu
        options.arrangedSubviews.forEach { $0.removeFromSuperview() }
        label.stringValue = menu?.title ?? Self.plain
        setAccessibilityLabel(label.stringValue)
        button.title = menu == nil ? "Ir para o terminal" : "Ver no terminal"
        guard let menu else {
            hint.stringValue = ""
            return
        }
        // The free-text option is the composer's: the rest are numbered as
        // shown, with no gap, while a press still sends the option's own digit.
        let shown = menu.options.filter { !($0.isFreeText && menu.freeText != nil) }
        for (index, option) in shown.enumerated() {
            let row = MenuOptionButton(option, position: index + 1)
            row.onPress = { [weak self] in self?.onChoose?(option) }
            options.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        }
        if menu.isMultiple {
            let next = NSButton(title: "Continuar", target: self, action: #selector(goOn))
            next.bezelStyle = .rounded
            options.addArrangedSubview(next)
        }
        hint.stringValue = menu.freeText != nil ? "Ou escreva a sua resposta abaixo e envie."
            : menu.isMultiple ? "Marque quantas quiser e continue." : ""
    }

    @objc private func go() { onGo?() }
    @objc private func goOn() { onNext?() }
}

/// One option of the maestro's menu: its number, its label, what it means.
final class MenuOptionButton: NSView {
    var onPress: (() -> Void)?
    private var isInside = false { didSet { paint() } }
    private let option: TerminalMenu.Option

    /// Claude Code's own fixed option, in the panel's language.
    private static let translated = ["Chat about this": "Conversar sobre isso"]

    init(_ option: TerminalMenu.Option, position: Int) {
        self.option = option
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        let mark = option.isChecked.map { $0 ? "☑" : "☐" } ?? String(position)
        let label = Self.translated[option.label] ?? option.label
        let number = NSTextField.label(mark, font: CockpitStyle.mono(12, .medium), color: CockpitStyle.accent)
        let title = NSTextField.label(label, font: ReadingStyle.smallMedium, color: ReadingStyle.text)
        let detail = NSTextField.label(option.detail ?? "", font: CockpitStyle.caption, color: ReadingStyle.quiet)
        detail.isHidden = option.detail == nil
        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        words.translatesAutoresizingMaskIntoConstraints = false
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(number)
        addSubview(words)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            number.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            words.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 9),
            words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            words.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([label, option.detail].compactMap { $0 }.joined(separator: ". "))
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func paint() {
        let lit = isInside || option.isChecked == true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isInside ? 0.09 : 0.04).cgColor
        layer?.borderColor = CockpitStyle.accent.withAlphaComponent(lit ? 0.55 : 0.18).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isInside = true }
    override func mouseExited(with event: NSEvent) { isInside = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// One press per click: the second of a double-click would be the same
    /// digit again, and answer the next question or permission unseen.
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Never a blank pane: when there is no transcript to read, why, and the way
/// back to the terminal.
final class LeituraEmptyState: NSView {
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ReadingStyle.page.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = ReadingStyle.faint
        icon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        let title = NSTextField.label("Comece a conversa", font: CockpitStyle.display, color: ReadingStyle.text)
        title.alignment = .center
        let body = NSTextField.wrapping(
            "Escreva a primeira mensagem para o maestro aqui embaixo. Se ele pedir algo antes de começar — confiar na pasta, entrar na conta —, isso aparece no terminal.",
            font: ReadingStyle.small, color: ReadingStyle.quiet
        )
        body.alignment = .center
        let button = NSButton(title: "Ver o terminal", target: self, action: #selector(back))
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            body.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func back() { onBack?() }
}

/// "↓ novas mensagens", floating over the list while the user reads higher up.
final class NewMessagesPill: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.tab.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = CockpitStyle.controlLine.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        let label = NSTextField.label("↓  novas mensagens", font: ReadingStyle.smallMedium, color: ReadingStyle.text)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Ir para as novas mensagens")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

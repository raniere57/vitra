import AppKit

/// "O maestro pede uma resposta no terminal": Leitura cannot answer a
/// permission prompt or any of Claude Code's interactive questions — those
/// live in the terminal's UI — so it says so plainly, with the way there.
final class PermissionBanner: NSView {
    var onGo: (() -> Void)?
    static let height: CGFloat = 46
    private let icon = NSImageView()
    private let label = NSTextField.label("O maestro pede uma resposta no terminal", font: ReadingStyle.smallMedium, color: ReadingStyle.text)
    private let button = NSButton()
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x2A / 255, green: 0x22 / 255, blue: 0x16 / 255, alpha: 1).cgColor
        let rule = NSView.rule(CockpitStyle.accent.withAlphaComponent(0.35))
        icon.image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        icon.contentTintColor = CockpitStyle.accent
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.title = "Ir para o terminal"
        button.keyEquivalent = ""
        button.target = self
        button.action = #selector(go)
        for view in [rule, icon, label, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightConstraint,
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.inset + 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CockpitStyle.inset),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("O maestro pede uma resposta no terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHidden: Bool {
        didSet { heightConstraint.constant = isHidden ? 0 : Self.height }
    }

    @objc private func go() { onGo?() }
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

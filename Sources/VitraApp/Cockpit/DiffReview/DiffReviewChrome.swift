import AppKit

/// The review's frame around the diff: a header that says whose delivery it
/// is, and a footer that counts the comments and sends them.
@MainActor
enum DiffReviewChrome {
    static func header(label: String, worker: String, summary: NSTextField, target: AnyObject, back: Selector) -> NSView {
        let backButton = NSButton(title: "", target: target, action: back)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Voltar")
        backButton.contentTintColor = CockpitStyle.muted
        backButton.isBordered = false
        backButton.bezelStyle = .inline
        backButton.toolTip = "Voltar (⎋)"
        backButton.widthAnchor.constraint(equalToConstant: CockpitStyle.iconSize).isActive = true
        let title = NSTextField.label(label, font: CockpitStyle.title, color: CockpitStyle.text)
        title.toolTip = label
        let who = NSTextField.label(worker, font: CockpitStyle.meta, color: CockpitStyle.muted)
        who.lineBreakMode = .byTruncatingMiddle
        summary.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The title gives way first, then the worker; the count never does.
        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        who.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(230), for: .horizontal)
        let row = NSStackView(views: [backButton, title, who, NSView(), summary])
        row.spacing = CockpitStyle.Space.md
        row.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.inset)
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    static func footer(count: NSTextField, status: NSTextField, buttons: [NSButton]) -> NSView {
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [count, status] + buttons)
        // The status takes the room between, which puts the buttons at the
        // right edge as in the workers' footer.
        row.distribution = .fill
        row.spacing = CockpitStyle.Space.lg
        row.setCustomSpacing(CockpitStyle.Space.md, after: buttons.first ?? status)
        row.edgeInsets = NSEdgeInsets(top: 0, left: CockpitStyle.inset, bottom: 0, right: CockpitStyle.inset)
        return row
    }

    static func arrange(header: NSView, body: NSView, message: NSView, footer: NSView, in view: NSView) {
        let headerRule = NSView.rule(CockpitStyle.softLine)
        let footerRule = NSView.rule(CockpitStyle.softLine)
        for part in [header, headerRule, body, message, footerRule, footer] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: CockpitStyle.headerHeight),
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            message.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            footerRule.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerRule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: CockpitStyle.footerHeight),
        ])
    }

    /// A plate button like the workers' "Parar todos"; the primary one says
    /// its title in the accent.
    static func button(_ title: String, target: AnyObject, action: Selector, primary: Bool) -> NSButton {
        let button = PlateButton(title: title, target: target, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = CockpitStyle.Radius.control
        button.layer?.backgroundColor = CockpitStyle.raised.cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        button.color = primary ? CockpitStyle.accent : CockpitStyle.text
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 24),
            button.widthAnchor.constraint(equalToConstant: button.intrinsicContentSize.width + 2 * CockpitStyle.Space.lg),
        ])
        return button
    }
}

/// A button whose title dims when it cannot be pressed: an attributed title
/// keeps its colour whatever the button's state.
private final class PlateButton: NSButton {
    var color = CockpitStyle.text {
        didSet { paint() }
    }

    override var isEnabled: Bool {
        didSet { paint() }
    }

    private func paint() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: CockpitStyle.label, .foregroundColor: isEnabled ? color : CockpitStyle.muted.withAlphaComponent(0.5),
        ])
    }
}

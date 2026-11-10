import AppKit

/// The Git tab: what was last done in the project's repository — commits,
/// pushes and pull requests — as one timeline, newest first.
final class GitPanel: NSView {
    /// A pull request was clicked.
    var onOpenURL: ((URL) -> Void)?

    private static let refreshEvery: TimeInterval = 5

    private let path: String
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var local: [GitEvent]? = []
    private var pulls: [GitEvent] = []
    private var shown: [GitEvent]?
    private var shownMinute = 0
    private var timer: Timer?

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Starts or stops following the repository. Only while the tab is the one
    /// on screen: nobody is reading it otherwise.
    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        reloadLocal()
        // Pull requests come over the network: once per visit, not per tick.
        GitHistory.loadPulls(in: path) { [weak self] pulls in
            self?.pulls = pulls
            self?.render()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLocal() }
        }
    }

    private func reloadLocal() {
        GitHistory.loadLocal(in: path) { [weak self] events in
            self?.local = events
            self?.render()
        }
    }

    private func render() {
        let events = local.map { GitHistory.timeline($0, pulls) }
        // Rebuilt only when something changed: the list is re-read every few
        // seconds, and rebuilding it each time would jump the scroll.
        // ...or when the minute turned, so "há 3 min" does not go stale.
        let minute = Int(Date().timeIntervalSince1970 / 60)
        guard events != shown || minute != shownMinute else { return }
        shown = events
        shownMinute = minute

        empty.stringValue = events == nil
            ? "Esta pasta não é um repositório git."
            : "Nenhum commit ainda."
        empty.isHidden = !(events ?? []).isEmpty
        scroll.isHidden = !empty.isHidden

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let now = Date()
        for event in events ?? [] {
            let row = self.row(event, when: GitHistory.stamp(event.date, now: now))
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -36).isActive = true
        }
    }

    private func row(_ event: GitEvent, when: String) -> NSView {
        let (symbol, tint, name): (String, NSColor, String) = switch event.kind {
        case .commit: ("smallcircle.filled.circle", CockpitStyle.muted, "commit")
        case .push: ("arrow.up.circle.fill", CockpitStyle.success, "push")
        case .pullRequest: ("arrow.triangle.pull", CockpitStyle.accent, "pull request")
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage())
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let title: NSView
        if let url = event.url.flatMap(URL.init(string:)) {
            // A button, so it is reached and pressed from the keyboard too.
            let link = LinkButton(title: event.title, url: url) { [weak self] in self?.onOpenURL?(url) }
            link.toolTip = "Abrir no navegador do Vitra"
            title = link
        } else {
            title = NSTextField.wrapping(event.title, font: CockpitStyle.ui(13, .medium), color: CockpitStyle.text, lines: 3)
        }
        // The date on a line of its own: the detail is cut when it is long,
        // and the when must never be what is cut.
        let date = NSTextField.label(when, font: CockpitStyle.mono(11), color: CockpitStyle.code)
        let detail = NSTextField.wrapping(event.detail, font: CockpitStyle.mono(11), color: CockpitStyle.muted, lines: 2)
        let text = NSStackView(views: [title, date, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        row.alignment = .top
        row.toolTip = event.title
        return row
    }

    private func build() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        rows.translatesAutoresizingMaskIntoConstraints = false

        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        addFilling(scroll)

        empty.font = CockpitStyle.ui(12)
        empty.textColor = CockpitStyle.muted
        empty.alignment = .center
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
        ])
    }
}

/// A scroll view's document that grows downwards from the top, as a list does.
final class TopDownView: NSView {
    override var isFlipped: Bool { true }
}

/// A line of text that is pressed like a button.
private final class LinkButton: NSButton {
    private let press: () -> Void

    init(title: String, url: URL, press: @escaping () -> Void) {
        self.press = press
        super.init(frame: .zero)
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: CockpitStyle.ui(13, .medium), .foregroundColor: CockpitStyle.text,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: CockpitStyle.controlLine,
        ])
        target = self
        action = #selector(pressed)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("\(title), abrir \(url.host ?? "")")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed() { press() }
}

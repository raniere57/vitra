import AppKit

/// The Git tab: what was last done in the project's repository — commits,
/// pushes and pull requests — as one timeline, newest first.
final class GitPanel: NSView {
    /// A pull request was clicked.
    var onOpenURL: ((URL) -> Void)?

    private static let refreshEvery: TimeInterval = 60

    private let path: String
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var local: [GitEvent]? = []
    private var pulls: [GitEvent] = []
    private var shown: [GitEvent]?
    private var shownStamps: [String] = []
    private var timer: Timer?
    private var watches: [DispatchSourceFileSystemObject] = []
    private var watchGeneration = 0
    private var pendingReload: DispatchWorkItem?

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        watches.forEach { $0.cancel() }
    }

    /// Starts or stops following the repository. Only while the tab is the one
    /// on screen: nobody is reading it otherwise.
    func setActive(_ active: Bool) {
        watchGeneration += 1
        stopWatching()
        timer?.invalidate()
        timer = nil
        guard active else { return }
        reloadLocal()
        // Pull requests come over the network: once per visit, not per tick.
        GitHistory.loadPulls(in: path) { [weak self] pulls in
            self?.pulls = pulls
            self?.render()
        }
        startWatching(generation: watchGeneration)
        // A watch on HEAD misses nothing a local commit does; this is only
        // for relative times going stale and for a fetch that never touches HEAD.
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLocal() }
        }
    }

    private func startWatching(generation: Int) {
        let path = self.path
        DispatchQueue.global(qos: .utility).async {
            guard let git = GitHistory.gitCommonDirectory(in: path) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.watchGeneration == generation else { return }
                // HEAD and its reflog for commits and pushes; the directory
                // itself because those files are replaced, which drops a watch
                // on the inode that was.
                for target in [git, git + "/HEAD", git + "/logs/HEAD"] {
                    self.watch(path: target)
                }
            }
        }
    }

    private func watch(path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.repositoryChanged() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watches.append(source)
    }

    private func stopWatching() {
        watches.forEach { $0.cancel() }
        watches.removeAll()
        pendingReload?.cancel()
        pendingReload = nil
    }

    /// One reload for a burst: a commit or a fetch writes the git directory
    /// many times over, and each reload is two git processes.
    private func repositoryChanged() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingReload = nil
            self?.reloadLocal()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func reloadLocal() {
        GitHistory.loadLocal(in: path) { [weak self] events in
            self?.local = events
            self?.render()
        }
    }

    private func render() {
        let events = local.map { GitHistory.timeline($0, pulls) }
        // Rebuilt only when the events changed: rebuilding would jump the scroll.
        // Relative times are rewritten in place so "há 3 min" does not go stale
        // without tearing the list down.
        let now = Date()
        let stamps = (events ?? []).map { GitHistory.stamp($0.date, now: now) }
        if events == shown {
            guard stamps != shownStamps else { return }
            shownStamps = stamps
            for (index, stamp) in stamps.enumerated() where index < rows.arrangedSubviews.count {
                guard let row = rows.arrangedSubviews[index] as? NSStackView,
                      let text = row.arrangedSubviews.last as? NSStackView,
                      text.arrangedSubviews.count > 1,
                      let date = text.arrangedSubviews[1] as? NSTextField
                else { continue }
                date.stringValue = stamp
            }
            return
        }
        shown = events
        shownStamps = stamps

        empty.stringValue = events == nil
            ? "Esta pasta não é um repositório git."
            : "Nenhum commit ainda."
        empty.isHidden = !(events ?? []).isEmpty
        scroll.isHidden = !empty.isHidden

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, event) in (events ?? []).enumerated() {
            let row = self.row(event, when: stamps[index])
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

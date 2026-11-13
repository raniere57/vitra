import AppKit
import QuickLookThumbnailing
import VitraCore
import VitraPanel

/// The Arquivos tab: the project's folders, or — picked from the strip on
/// top — every image, video or text in it, most recently changed first.
final class FilesArea: NSView {
    /// Where the file panel lives when it does not have the whole project.
    let panelSlot = NSView()

    private static let folders = "pastas"

    private let strip = BrowserTabStrip(showsNew: false)
    private let recent = RecentFilesView()
    private let panel: PreviewPanel
    private let root: URL
    private var chosen = FilesArea.folders
    /// Which file of the list is open, when one is: what Back returns from,
    /// and where the arrows and the swipe step from.
    private var openIndex: Int?
    private var monitor: Any?
    private var swipe = (x: CGFloat(0), y: CGFloat(0), fired: false)

    init(panel: PreviewPanel, root: URL) {
        self.panel = panel
        self.root = root
        super.init(frame: .zero)
        let rule = NSView.rule(CockpitStyle.softLine)
        for view in [strip, rule, panelSlot, recent] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        panelSlot.addFilling(panel)
        strip.onSelect = { [weak self] id in self?.choose(id) }
        recent.onOpen = { [weak self] url in self?.open(url) }
        // Back from a file opened out of a list goes to that list, not to the
        // folder the file happens to live in.
        panel.onBack = { [weak self] in
            guard let self, self.openIndex != nil, let kind = RecentFiles.Kind(rawValue: self.chosen) else { return false }
            self.showList(of: kind, reloading: false)
            return true
        }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: BrowserTabStrip.height),
            rule.topAnchor.constraint(equalTo: strip.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for view in [panelSlot, recent] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: rule.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        showPanel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Brings the file panel forward, for a file something else opened in it.
    func showPanel() {
        openIndex = nil
        revealPanel()
    }

    private func revealPanel() {
        recent.isHidden = true
        panelSlot.isHidden = false
        paintStrip()
    }

    /// Back to the folders, as when the tab is closed and opened again.
    func reset() {
        chosen = Self.folders
        showPanel()
    }

    private func choose(_ id: String) {
        chosen = id
        guard let kind = RecentFiles.Kind(rawValue: id) else {
            // Pressed again while a file is open: back to the folder list.
            if panel.target != nil || !panel.isListingFiles { panel.showFiles(in: root) }
            showPanel()
            return
        }
        showList(of: kind, reloading: true)
    }

    private func showList(of kind: RecentFiles.Kind, reloading: Bool) {
        openIndex = nil
        paintStrip()
        panelSlot.isHidden = true
        recent.isHidden = false
        if reloading { recent.load(kind, in: root) }
    }

    private func open(_ url: URL) {
        guard let target = PreviewTarget.resolve(path: url.path) else { return }
        panel.rememberDirectory(url.deletingLastPathComponent())
        panel.show(target)
        openIndex = recent.entries.firstIndex { $0.url == url }
        revealPanel()
        // So the arrow keys reach here and not the terminal.
        window?.makeFirstResponder(self)
    }

    /// Opens the file before or after the one open, in the list's order.
    private func step(_ by: Int) {
        guard let index = openIndex, recent.entries.indices.contains(index + by) else { return }
        open(recent.entries[index + by].url)
    }

    // MARK: - Arrows and swipe

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Left and right step through the list while a file from it is open and
    /// the keyboard is here; so does a two-finger swipe sideways over an
    /// image or a video. Text keeps its sideways scroll: long lines need it.
    private func consumes(_ event: NSEvent) -> Bool {
        guard openIndex != nil, event.window === window, !panelSlot.isHidden else { return false }
        if event.type == .keyDown {
            let here = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
            let arrows: [UInt16: Int] = [123: -1, 124: 1]
            guard here, let by = arrows[event.keyCode], event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            step(by)
            return true
        }
        guard chosen != RecentFiles.Kind.text.rawValue, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              panelSlot.bounds.contains(panelSlot.convert(event.locationInWindow, from: nil))
        else { return false }
        if event.phase == .began { swipe = (0, 0, false) }
        swipe.x += event.scrollingDeltaX
        swipe.y += abs(event.scrollingDeltaY)
        // Clearly sideways, and far enough to be meant; once per gesture.
        if !swipe.fired, abs(swipe.x) > 70, abs(swipe.x) > 2 * swipe.y {
            swipe.fired = true
            step(swipe.x < 0 ? 1 : -1)
        }
        return false
    }

    private func paintStrip() {
        let items = [
            (Self.folders, "Pastas", "As pastas do projeto"),
            (RecentFiles.Kind.image.rawValue, "Imagens", "Todas as imagens do projeto, da mais recente para a mais antiga"),
            (RecentFiles.Kind.video.rawValue, "Vídeos", "Todos os vídeos do projeto, do mais recente para o mais antigo"),
            (RecentFiles.Kind.text.rawValue, "Textos", "Todos os textos e códigos do projeto, do mais recente para o mais antigo"),
        ].map { BrowserTabStrip.Item(id: $0.0, label: $0.1, tip: $0.2) }
        strip.show(items, current: chosen)
    }
}

/// A flat list of files with a thumbnail each, newest first.
final class RecentFilesView: NSView {
    var onOpen: ((URL) -> Void)?

    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let note = NSTextField(wrappingLabelWithString: "")
    /// What the list holds, in the order shown.
    private(set) var entries: [RecentFiles.Entry] = []
    /// Counts the searches, so one that finishes late does not overwrite a newer.
    private var search = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = CockpitStyle.Space.xs
        // The rows' plates start 8 pt inside the inset, so that the thumbnails
        // line up with the content inset of everything else.
        rows.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.md, left: CockpitStyle.inset - CockpitStyle.Space.md, bottom: CockpitStyle.Space.md, right: CockpitStyle.inset - CockpitStyle.Space.md)
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        addFilling(scroll)
        note.font = CockpitStyle.ui(12)
        note.textColor = CockpitStyle.muted
        note.alignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func load(_ kind: RecentFiles.Kind, in root: URL) {
        search += 1
        let this = search
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        note.stringValue = "Procurando…"
        note.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = RecentFiles.find(in: root, kind: kind)
            DispatchQueue.main.async { [weak self] in
                guard let self, this == self.search else { return }
                self.show(entries, root: root)
            }
        }
    }

    /// Internal, not private: the UI snapshot tool fills the list with it
    /// directly instead of waiting on the search's trip through the main queue.
    func show(_ entries: [RecentFiles.Entry], root: URL) {
        self.entries = entries
        note.stringValue = "Nenhum arquivo desse tipo no projeto."
        note.isHidden = !entries.isEmpty
        let now = Date()
        for entry in entries {
            let folder = entry.url.deletingLastPathComponent().path.dropFirst(root.path.count).drop { $0 == "/" }
            let row = RecentFileRow(
                url: entry.url,
                detail: [GitHistory.stamp(entry.modified, now: now), folder.isEmpty ? nil : String(folder)].compactMap { $0 }.joined(separator: " · ")
            ) { [weak self] in self?.onOpen?(entry.url) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -2 * (CockpitStyle.inset - CockpitStyle.Space.md)).isActive = true
        }
    }
}

/// One file: a thumbnail, its name, and when it changed and where it is.
private final class RecentFileRow: NSButton {
    private static let thumbnail: CGFloat = 44
    private let press: () -> Void

    init(url: URL, detail: String, press: @escaping () -> Void) {
        self.press = press
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.card
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("\(url.lastPathComponent), \(detail)")
        toolTip = url.path

        let picture = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = CockpitStyle.Radius.thumb
        picture.layer?.masksToBounds = true
        let name = NSTextField.label(url.lastPathComponent, font: CockpitStyle.ui(13, .medium), color: CockpitStyle.text)
        name.lineBreakMode = .byTruncatingMiddle
        let when = NSTextField.label(detail, font: CockpitStyle.meta, color: CockpitStyle.muted)
        when.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [name, when])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [picture, text])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            picture.widthAnchor.constraint(equalToConstant: Self.thumbnail),
            picture.heightAnchor.constraint(equalToConstant: Self.thumbnail),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        // The picture itself, small, as soon as the system has drawn it; the
        // file's icon stands in until then, and stays if it cannot be drawn.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: Self.thumbnail, height: Self.thumbnail),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak picture] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { picture?.image = image }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed() { press() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = CockpitStyle.raised.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

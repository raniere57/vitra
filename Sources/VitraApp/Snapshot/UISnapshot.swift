import AppKit
import Metal
import VitraCore
import VitraOrchestrator
import VitraPanel

/// `Vitra snapshot <dir>`: draws the cockpit's views offscreen, with made-up
/// data, and writes them as PNGs. A process drawing its own views needs no
/// screen-recording permission and no running Vitra, so an agent can look at
/// the interface it is changing.
///
/// What cannot render offscreen — the Metal terminal and WKWebView pages — is
/// replaced by a plate with a label, in the snapshot only.
@MainActor
enum UISnapshot {
    static let scale: CGFloat = 2

    /// One picture: its file name (without extension) and its size in points.
    struct Shot {
        let name: String
        let size: NSSize
        /// Builds what is drawn. May put things straight into the window's
        /// content view instead and return nil.
        let build: @MainActor (Context) throws -> NSView?
    }

    struct Context {
        let fixtures: SnapshotFixtures
        let window: NSWindow
    }

    static let shots: [Shot] = [
        Shot(name: "window-1440", size: NSSize(width: 1440, height: 900), build: { try cockpit($0) }),
        Shot(name: "window-min", size: CockpitWindowController.minSize, build: { try cockpit($0) }),
        Shot(name: "workers", size: NSSize(width: 420, height: 720), build: { context in
            let panel = WorkersPanel()
            panel.show(context.fixtures.workerRuns(), now: context.fixtures.now)
            return panel
        }),
        Shot(name: "ranking", size: NSSize(width: 420, height: 720), build: { context in
            let view = RankingView()
            view.show(WorkerBoard.ranking(context.fixtures.rankingScores()))
            return view
        }),
        Shot(name: "git", size: NSSize(width: 420, height: 720), build: { context in
            let panel = GitPanel(path: context.fixtures.path)
            panel.show(context.fixtures.gitEvents())
            return panel
        }),
        Shot(name: "files", size: NSSize(width: 720, height: 600), build: { context in
            let panel = PreviewPanel()
            panel.showFiles(in: context.fixtures.project)
            return FilesArea(panel: panel, root: context.fixtures.project)
        }),
        Shot(name: "recent-images", size: NSSize(width: 420, height: 560), build: { try recent(.image, $0) }),
        Shot(name: "recent-texts", size: NSSize(width: 420, height: 560), build: { try recent(.text, $0) }),
        Shot(name: "browser-tabs", size: NSSize(width: 720, height: 140), build: { context in
            let strip = BrowserTabStrip()
            strip.show([
                .init(id: BrowserTabs.maestro, label: BrowserTabs.label(BrowserTabs.maestro, runTitle: nil), tip: "maestro"),
                .init(id: "você", label: "você", tip: "você"),
                .init(id: "a1b2c3d4", label: BrowserTabs.label("a1b2c3d4", runTitle: "Migrar a lista de arquivos"), tip: "worker"),
            ], current: "você")
            let area = NSView()
            let page = placeholder("web")
            for view in [strip, page] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                area.addSubview(view)
            }
            NSLayoutConstraint.activate([
                strip.topAnchor.constraint(equalTo: area.topAnchor),
                strip.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                strip.heightAnchor.constraint(equalToConstant: BrowserTabStrip.height),
                page.topAnchor.constraint(equalTo: strip.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            ])
            return area
        }),
        Shot(name: "preview-header", size: NSSize(width: 560, height: 220), build: { context in
            let panel = PreviewPanel()
            guard let target = PreviewTarget.resolve(path: context.fixtures.project.appendingPathComponent("docs/plan.md").path) else {
                throw SnapshotError.render("could not open the fixture file")
            }
            panel.rememberDirectory(context.fixtures.project.appendingPathComponent("docs"))
            panel.show(target)
            return panel
        }),
        Shot(name: "quit-hold", size: NSSize(width: 480, height: 140), build: { context in
            context.window.contentView?.addFilling(placeholder("terminal"))
            QuitHold().show(in: context.window)
            return nil
        }),
    ]

    /// Writes every picture into `directory`, which is created if need be, and
    /// returns the files in the order of `shots`.
    @discardableResult
    static func run(into directory: URL) throws -> [URL] {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.appearance = NSAppearance(named: .darkAqua)

        // Under /tmp, not the per-user temp folder: the project's path is drawn
        // in the header, and that one is long enough to squeeze the other plates.
        // The real folder behind /tmp, because the file search reports real paths
        // and the lists show them relative to the project's.
        let scratch = URL(fileURLWithPath: "/private/tmp/vs\(UUID().uuidString.prefix(4))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixtures = try SnapshotFixtures.makeProject(in: scratch, now: Date())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try shots.map { shot in
            let url = directory.appendingPathComponent(shot.name + ".png")
            try write(shot, fixtures: fixtures, to: url)
            return url
        }
    }

    // MARK: - Views

    /// The whole window, composed by hand: the tab bar over a `ProjectView`
    /// that never started its terminal. The controller itself starts a shell
    /// and reads the user's saved projects, so it is not used here.
    private static func cockpit(_ context: Context) throws -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SnapshotError.render("no Metal device") }
        let fixtures = context.fixtures
        let project = ProjectView(
            project: CockpitProject(path: fixtures.path),
            kit: TerminalKit(device: device, config: Config()),
            startsTerminal: false
        )
        project.terminalArea.addFilling(placeholder("terminal"))
        project.show(usage: fixtures.usage)
        project.show(model: fixtures.maestro)
        let runs = fixtures.workerRuns()
        project.show(runs, now: fixtures.now)

        // The selected tab asks for a permission and the next one waits; the
        // third is quiet, so all three tab looks are in the picture.
        let attention = fixtures.attention()
        project.show(attention: AttentionPolicy.label(attention[fixtures.path], now: fixtures.now))

        let bar = CockpitTabBar()
        bar.show([
            .init(name: "vitra", running: WorkerBoard.runningCount(runs), callsForYou: AttentionPolicy.isCalling(attention[fixtures.path], now: fixtures.now)),
            .init(name: "hapto", running: 0, callsForYou: AttentionPolicy.isCalling(attention["hapto"], now: fixtures.now)),
            .init(name: "docs", running: 0),
        ], selected: 0)
        bar.show(chips: ProviderChips.derive(runs: fixtures.chipRuns(), usage: fixtures.subscription, now: fixtures.now))
        bar.show(costToday: WorkerBoard.totals(runs, since: Calendar.current.startOfDay(for: fixtures.now)).cost)

        let window = NSView()
        for view in [bar, project] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: window.topAnchor),
            bar.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: CockpitStyle.barHeight),
            project.topAnchor.constraint(equalTo: bar.bottomAnchor),
            project.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            project.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            project.bottomAnchor.constraint(equalTo: window.bottomAnchor),
        ])
        return window
    }

    /// A recent-files list, once the search has run and the system has had a
    /// moment to draw thumbnails.
    private static func recent(_ kind: RecentFiles.Kind, _ context: Context) throws -> NSView {
        let list = RecentFilesView()
        let root = context.fixtures.project
        list.show(RecentFiles.find(in: root, kind: kind), root: root)
        guard !list.entries.isEmpty else { throw SnapshotError.render("the \(kind) list is empty") }
        // Thumbnails arrive from the system on the main queue; the file's own
        // icon stands in where they do not.
        settle(timeout: 1.5, until: { false })
        return list
    }

    /// A flat plate standing for what cannot be drawn offscreen.
    private static func placeholder(_ text: String) -> NSView {
        let plate = NSView.filled(CockpitStyle.panel)
        let label = NSTextField.label(text, font: CockpitStyle.mono(13), color: CockpitStyle.muted)
        label.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        return plate
    }

    // MARK: - Drawing

    private static func write(_ shot: Shot, fixtures: SnapshotFixtures, to url: URL) throws {
        // A window that is never ordered in: the views get a real layout and
        // appearance, and nothing reaches the screen.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CockpitStyle.ground
        let host = NSView(frame: NSRect(origin: .zero, size: shot.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = CockpitStyle.ground.cgColor
        window.contentView = host

        if let view = try shot.build(Context(fixtures: fixtures, window: window)) { host.addFilling(view) }
        host.layoutSubtreeIfNeeded()
        // A turn of the run loop, so what lays itself out late (scroll views,
        // tables) has done it before the picture is taken.
        settle(timeout: 0.15, until: { false })
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let rep = try bitmap(of: host, size: shot.size)
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.render("could not encode \(shot.name)")
        }
        try data.write(to: url)
    }

    /// A bitmap at `scale` times the view's size in pixels. The system's own
    /// cache rep follows the window's screen, and a window that is not on one
    /// may give 1x; when it does not give 2x, the rep is made by hand.
    private static func bitmap(of view: NSView, size: NSSize) throws -> NSBitmapImageRep {
        let pixels = (width: Int(size.width * scale), height: Int(size.height * scale))
        if let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds),
           cached.pixelsWide == pixels.width, cached.pixelsHigh == pixels.height {
            return cached
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels.width, pixelsHigh: pixels.height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw SnapshotError.render("could not allocate a bitmap") }
        // Pixels at 2x, points at 1x: cacheDisplay then draws at 2x.
        rep.size = size
        return rep
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private static func settle(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

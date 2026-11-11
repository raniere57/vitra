import AppKit
import VitraOrchestrator
import VitraPanel

/// The Palco tab: a live stage of the orchestration over a timeline of it.
///
/// It owns the liveness. Nothing here, nor in the two views, runs while the
/// tab is out of sight, the window cannot be seen, or nothing is running:
/// the repeating animations are attached only when `StageLiveness.animates`,
/// the clock and the bars move by the cockpit's own one-second feed (the same
/// one that updates the Workers tab), and the only timer is a single shot for
/// the moment a finished worker is due to leave.
final class PalcoView: NSView {
    /// The stage and the timeline split the tab 60 / 40.
    private static let stageShare: CGFloat = 0.6

    /// A worker was clicked, on the stage or in the timeline.
    var onOpenWorker: ((String) -> Void)?

    private let stage = StageView()
    private let timeline = TimelineView()
    private let isStill: Bool
    private let reduceMotionOverride: Bool?
    private let repository: String?

    private var runs: [Run] = []
    private var now = Date()
    private var model: MaestroModel?
    private var week: Double?
    private var branch: String?
    private var nodes: [StageNode] = []
    private var merge = MergeTracker()
    private var wasOnScreen = false
    private var expiry: Timer?
    private var branchWatch: BranchWatch?
    private struct Observation {
        let center: NotificationCenter
        nonisolated(unsafe) let token: NSObjectProtocol
        func remove() { center.removeObserver(token) }
    }
    private var observers: [Observation] = []

    /// `isStill` is for the UI snapshot tool: the picture is drawn at once with
    /// the particles frozen mid-link, as if the tab were on screen.
    init(repository: String? = nil, isStill: Bool = false, reduceMotion: Bool? = nil) {
        self.repository = repository
        self.isStill = isStill
        reduceMotionOverride = reduceMotion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        for view in [stage, timeline] { addSubview(view) }
        stage.onSelect = { [weak self] id in self?.onOpenWorker?(id) }
        timeline.onSelect = { [weak self] id in self?.onOpenWorker?(id) }
        stage.showsStillParticles = isStill
        applyMotionSetting()
        if isStill {
            stage.contentsScale = UISnapshot.scale
            timeline.contentsScale = UISnapshot.scale
        }
        if let repository, !isStill {
            branchWatch = BranchWatch(path: repository) { [weak self] existing in self?.branchesRead(existing) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Data

    /// Takes the cockpit's latest runs. Drawn at once only when the tab is on
    /// screen; otherwise kept for when it is.
    func show(_ runs: [Run], now: Date) {
        self.runs = runs
        self.now = now
        guard isOnScreen else { return }
        render(animated: true)
    }

    func show(model: MaestroModel?) {
        self.model = model
        if isOnScreen { render(animated: false) }
    }

    func show(usageText: String?) {
        week = usageText.flatMap(StageModel.percent(inUsageText:))
        if isOnScreen { render(animated: false) }
    }

    func setBranch(_ name: String?) {
        branch = name
        if isOnScreen { render(animated: false) }
    }

    /// Deliveries already known to be merged, for a still picture.
    func seedMerged(_ ids: [String]) {
        _ = merge.update(branches: Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }), existing: Set(ids))
        _ = merge.update(branches: Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }), existing: [])
        if isOnScreen { render(animated: false) }
    }

    /// Shows one worker's card, as the pointer would. For a still picture.
    func hover(_ id: String?) {
        hovered = id
        stage.showCard(for: id)
    }
    private var hovered: String?

    private func render(animated: Bool) {
        nodes = StageModel.nodes(from: runs, now: now)
        let delivered = runs.filter { $0.state != .running }.compactMap(\.ended).max()
        let state = StageState(
            nodes: nodes, now: now, modelTitle: StageModel.coreTitle(model?.name), effort: model?.effort, week: week,
            lastDelivery: delivered, branch: branch, merged: merge.recent()
        )
        let live = refreshLiveness()
        stage.update(state, animated: animated)
        timeline.update(nodes, now: now, glide: live)
        scheduleExpiry()
        if let branchWatch, branchWatch.isActive != wantsBranchWatch {
            if wantsBranchWatch { branchWatch.start() } else { branchWatch.stop() }
        }
    }

    /// Whether a finished worker's branch is still worth watching for.
    private var wantsBranchWatch: Bool {
        isOnScreen && (
            nodes.contains { $0.outcome != .running && $0.branch != nil && !merge.merged.contains($0.id) }
                || !acceptedEdits.subtracting(merge.merged).isEmpty
        )
    }

    private func branchesRead(_ existing: Set<String>) {
        let branches = Dictionary(
            runs.compactMap { run in run.branch.map { (run.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard !merge.update(branches: branches, existing: existing, accepted: acceptedEdits).isEmpty, isOnScreen else { return }
        render(animated: true)
    }

    /// Finished editing runs rated 4 or more: taken by the maestro, so merged
    /// once their branch is gone, seen before or not.
    private var acceptedEdits: Set<String> {
        // Only those on the stage: older ones are not news.
        let shown = Set(nodes.map(\.id))
        return Set(runs.filter { run in
            guard shown.contains(run.id), case .finished = run.state else { return false }
            return run.spec.access == .edit && (run.rating?.score ?? 0) >= 4
        }.map(\.id))
    }

    // MARK: Liveness

    /// Whether the tab can be seen: in a window that can be seen, not hidden.
    private var isOnScreen: Bool {
        if isStill { return true }
        guard let window else { return false }
        return !isHiddenOrHasHiddenAncestor && window.occlusionState.contains(.visible)
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Turns the repeating animations on or off to match what can be seen.
    @discardableResult
    private func refreshLiveness() -> Bool {
        let hasRunning = nodes.contains { $0.outcome == .running }
        let live = !isStill && StageLiveness.animates(isOnScreen: isOnScreen, hasRunning: hasRunning, reduceMotion: reduceMotion)
        stage.setLive(live)
        timeline.setLive(live)
        return live
    }

    private func applyMotionSetting() {
        stage.reduceMotion = reduceMotion
        timeline.reduceMotion = reduceMotion
    }

    private func motionSettingChanged() {
        applyMotionSetting()
        refreshLiveness()
    }

    /// The tab came or went: draw what has happened meanwhile, in place, and
    /// start or stop what moves.
    private func visibilityChanged() {
        let onScreen = isOnScreen
        defer { wasOnScreen = onScreen }
        guard onScreen != wasOnScreen else { return }
        if onScreen {
            now = Date()
            render(animated: false)
            stage.setVisible(!isStill)
        } else {
            stage.setVisible(false)
            _ = refreshLiveness()
            expiry?.invalidate()
            expiry = nil
            branchWatch?.stop()
        }
    }

    /// One shot, for when a finished worker is next due to leave the stage.
    private func scheduleExpiry() {
        expiry?.invalidate()
        expiry = nil
        guard isOnScreen, !isStill, let due = StageModel.nextExpiry(nodes) else { return }
        let timer = Timer(fire: max(due, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                self.render(animated: true)
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Watched only while in a window: a tab that is out of the hierarchy
        // listens to nothing.
        observers.forEach { $0.remove() }
        observers = []
        if let window {
            let occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
            let motion = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.motionSettingChanged() } }
            observers = [Observation(center: .default, token: occlusion), Observation(center: NSWorkspace.shared.notificationCenter, token: motion)]
            applyMotionSetting()
        }
        visibilityChanged()
        if let scale = window?.backingScaleFactor, !isStill {
            stage.contentsScale = scale
            timeline.contentsScale = scale
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        visibilityChanged()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityChanged()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let top = (bounds.height * Self.stageShare).rounded()
        stage.frame = CGRect(x: 0, y: bounds.height - top, width: bounds.width, height: top)
        timeline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - top)
        if isStill {
            render(animated: false)
            stage.showCard(for: hovered)
        }
    }
}

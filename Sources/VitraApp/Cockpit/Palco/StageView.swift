import AppKit
import QuartzCore
import VitraPanel

/// What the stage is shown.
struct StageState {
    var nodes: [StageNode] = []
    var now = Date()
    var modelTitle = "claude"
    var effort: String?
    /// The week's usage, 0...100, when known.
    var week: Double?
    var lastDelivery: Date?
    var branch: String?
    /// Ids of the deliveries merged into the branch, oldest first.
    var merged: [String] = []
}

/// The top of the Palco: the maestro at the centre, each worker on an orbit
/// around it, a link between them, and the branch along the bottom.
///
/// Everything is a layer. Between updates nothing here runs: the particles, the
/// breathing, the glow and the turning ring are `CAAnimation`s that the render
/// server plays, attached only while `isLive` and removed when it turns off.
final class StageView: NSView {
    private static let particlesPerLink = 3
    private static let particleCycle: CFTimeInterval = 2.6
    private static let enter: CFTimeInterval = 0.7

    /// A worker was clicked.
    var onSelect: ((String) -> Void)?
    /// Draw particles at fixed places along the links: for a still picture.
    var showsStillParticles = false
    var reduceMotion = false { didSet { if oldValue != reduceMotion { refreshMotion() } } }
    /// Resolution of the text layers; the window's, unless set (a snapshot).
    var contentsScale: CGFloat = 2 {
        didSet { rootLayer.setContentsScaleRecursively(contentsScale) }
    }
    private(set) var isLive = false

    private final class Entry {
        let layer: StageNodeLayer
        let link = CAShapeLayer()
        var particles: [CALayer] = []
        var curve = LinkCurve(from: .zero, to: .zero, bend: 1)
        var target = CGPoint.zero
        init(layer: StageNodeLayer) { self.layer = layer }
    }

    private let rootLayer = CALayer()
    private let backdrop = CAGradientLayer()
    private let orbits = CAShapeLayer()
    private let linksLayer = CALayer()
    private let nodesLayer = CALayer()
    private let core = StageCoreLayer()
    private let trunk = StageTrunkLayer()
    private let card = StageCardLayer()
    private let emptyTitle = CATextLayer.line(CockpitStyle.ui(12, .medium), CockpitStyle.text)
    private let emptyNote = CATextLayer.line(CockpitStyle.ui(11), CockpitStyle.muted)

    private var state = StageState()
    private var slots = SlotBook()
    private var entries: [String: Entry] = [:]
    private var geometry = StageGeometry(size: .zero)
    private var sparkled: Set<String> = []
    private var hovered: String?
    private var hasShownOnce = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = rootLayer
        wantsLayer = true
        rootLayer.masksToBounds = true
        backdrop.type = .radial
        backdrop.startPoint = CGPoint(x: 0.5, y: 0.5)
        backdrop.endPoint = CGPoint(x: 1, y: 1)
        backdrop.colors = [CockpitStyle.raised.withAlphaComponent(0.85).cgColor, CockpitStyle.panel.withAlphaComponent(0).cgColor]
        orbits.fillColor = nil
        orbits.strokeColor = CockpitStyle.softLine.cgColor
        orbits.lineWidth = 1
        orbits.lineDashPattern = [2, 5]
        for layer in [backdrop, orbits, linksLayer, core, nodesLayer, trunk, emptyTitle, emptyNote, card] as [CALayer] {
            rootLayer.addSublayer(layer)
        }
        rootLayer.setContentsScaleRecursively(contentsScale)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Palco: o maestro e seus operários")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Showing

    /// Shows `state`. `animated` lets new workers fly out and leaving ones drift
    /// away; off, everything lands where it belongs at once.
    func update(_ state: StageState, animated: Bool) {
        let previous = self.state
        self.state = state
        let animated = animated && hasShownOnce && !showsStillParticles
        hasShownOnce = true
        slots.update(ids: state.nodes.filter { $0.auditOf == nil }.map(\.id))
        let targets = targetPositions(state.nodes)
        let ids = Set(state.nodes.map(\.id))

        for (id, entry) in entries where !ids.contains(id) { remove(entry, id: id, animated: animated) }
        for node in state.nodes {
            guard let target = targets[node.id] else { continue }
            let old = previous.nodes.first { $0.id == node.id }
            let entry = entries[node.id] ?? makeEntry(node, animated: animated)
            entry.target = target
            place(entry, node: node, targets: targets)
            if let old, old.outcome == .running, node.outcome != .running {
                settle(entry, node: node, animated: animated)
            }
            entry.layer.apply(node)
            if node.score == 5, !sparkled.contains(node.id) {
                sparkled.insert(node.id)
                entry.layer.sparkle(animated: animated)
            }
        }
        refreshStatic()
        dropMerged(previous: previous, animated: animated)
        refreshMotion()
    }

    private func targetPositions(_ nodes: [StageNode]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for node in nodes where node.auditOf == nil {
            if let slot = slots.slots[node.id] { result[node.id] = geometry.position(ofSlot: slot) }
        }
        for node in nodes {
            if let parent = node.auditOf, let point = result[parent] { result[node.id] = geometry.auditPosition(besideDelivery: point) }
        }
        return result
    }

    private func makeEntry(_ node: StageNode, animated: Bool) -> Entry {
        let layer = StageNodeLayer(radius: node.isAudit ? StageGeometry.auditRadius : StageGeometry.nodeRadius, isAudit: node.isAudit)
        let entry = Entry(layer: layer)
        entry.link.fillColor = nil
        entry.link.lineWidth = 1
        entry.link.lineCap = .round
        entry.link.lineDashPattern = node.isAudit ? [3, 4] : nil
        entries[node.id] = entry
        linksLayer.addSublayer(entry.link)
        nodesLayer.addSublayer(layer)
        layer.setContentsScaleRecursively(contentsScale)
        layer.apply(node)
        guard animated else { return entry }
        let from = node.auditOf.flatMap { entries[$0]?.layer.position } ?? up(geometry.center)
        if reduceMotion {
            fade(layer, from: 0, to: 1, duration: 0.25)
            fade(entry.link, from: 0, to: 1, duration: 0.25)
        } else {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = from
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.25
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            layer.add(CAAnimationGroup.of([move, grow, appear], duration: Self.enter, timing: CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)), forKey: "enter")
            fade(entry.link, from: 0, to: 1, duration: Self.enter)
        }
        return entry
    }

    /// Puts a node and its link where the geometry says.
    private func place(_ entry: Entry, node: StageNode, targets: [String: CGPoint]) {
        let from = node.auditOf.flatMap { targets[$0] } ?? geometry.center
        let slot = slots.slots[node.id] ?? 0
        let curve = LinkCurve(from: up(from), to: up(entry.target), bend: node.auditOf != nil ? 1 : (slot % 4 < 2 ? 1 : -1))
        entry.layer.placeText(above: entry.target.y < geometry.center.y - 8)
        CALayer.instantly {
            entry.layer.position = up(entry.target)
            entry.link.path = curve.path
            let tint = StagePalette.state(node)
            let strength: CGFloat = node.outcome == .running ? 0.5 : 0.22
            entry.link.strokeColor = tint.withAlphaComponent(strength).cgColor
        }
        if curve != entry.curve {
            entry.curve = curve
            // The particles ride the old path until they are re-laid.
            removeParticles(entry)
        }
    }

    private func remove(_ entry: Entry, id: String, animated: Bool) {
        entries[id] = nil
        removeParticles(entry)
        guard animated else {
            entry.layer.removeFromSuperlayer()
            entry.link.removeFromSuperlayer()
            return
        }
        // Outward, away from the core, and gone.
        let away = CGPoint(x: entry.target.x - geometry.center.x, y: entry.target.y - geometry.center.y)
        let length = max(hypot(away.x, away.y), 1)
        let drift = reduceMotion ? CGPoint.zero : CGPoint(x: away.x / length * 26, y: -away.y / length * 26)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            entry.layer.removeFromSuperlayer()
            entry.link.removeFromSuperlayer()
        }
        let out = CABasicAnimation(keyPath: "position")
        out.fromValue = entry.layer.position
        out.toValue = CGPoint(x: entry.layer.position.x + drift.x, y: entry.layer.position.y + drift.y)
        let gone = CABasicAnimation(keyPath: "opacity")
        gone.fromValue = entry.layer.opacity
        gone.toValue = 0
        let group = CAAnimationGroup.of(reduceMotion ? [gone] : [out, gone], duration: reduceMotion ? 0.25 : 0.8, timing: CAMediaTimingFunction(name: .easeIn))
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        entry.layer.add(group, forKey: "leave")
        fade(entry.link, from: 1, to: 0, duration: 0.5, keep: true)
        CATransaction.commit()
    }

    /// A worker finished: a bright pulse goes home along its link, and the core answers.
    private func settle(_ entry: Entry, node: StageNode, animated: Bool) {
        removeParticles(entry)
        entry.layer.setGlowing(false)
        guard animated else { return }
        let fadeState = CATransition()
        fadeState.type = .fade
        fadeState.duration = 0.35
        entry.layer.add(fadeState, forKey: "settle")
        guard !reduceMotion else { return }
        let pulse = CAShapeLayer()
        let size: CGFloat = 8
        pulse.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        pulse.path = CGPath(ellipseIn: pulse.bounds, transform: nil)
        pulse.fillColor = StagePalette.light(StagePalette.state(node), 0.55).cgColor
        pulse.shadowColor = StagePalette.state(node).cgColor
        pulse.shadowOpacity = 1
        pulse.shadowRadius = 6
        pulse.shadowOffset = .zero
        pulse.opacity = 0
        let home = entry.curve.reversed
        pulse.position = home.to
        linksLayer.addSublayer(pulse)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = home.path
        move.calculationMode = .paced
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.85, 1]
        let group = CAAnimationGroup.of([move, fade], duration: 0.95, timing: CAMediaTimingFunction(name: .easeIn))
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            pulse.removeFromSuperlayer()
            if node.auditOf == nil { self?.core.absorb() }
        }
        pulse.add(group, forKey: "home")
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval, keep: Bool = false) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        if keep {
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
        }
        layer.add(fade, forKey: "fade")
    }

    // MARK: Static parts

    private func refreshStatic() {
        let nodes = state.nodes
        CALayer.instantly {
            core.configure(title: state.modelTitle, effort: state.effort, week: state.week)
            trunk.setBranch(state.branch)
            let hasInner = nodes.contains { node in (slots.slots[node.id] ?? 0) % 2 == 1 }
            orbits.path = orbitsPath(inner: hasInner)
            let isEmpty = nodes.isEmpty
            emptyTitle.isHidden = !isEmpty
            emptyNote.isHidden = !isEmpty
            emptyTitle.string = "Sem operários em campo"
            emptyNote.string = state.lastDelivery.map { "última entrega às " + WorkerBoard.startedText($0, now: state.now) } ?? "nenhuma entrega ainda"
        }
        setAccessibilityValue(nodes.isEmpty ? "sem operários em campo" : "\(nodes.filter { $0.outcome == .running }.count) rodando, \(nodes.count) no palco")
    }

    private func orbitsPath(inner: Bool) -> CGPath {
        let path = CGMutablePath()
        let radii = geometry.radii
        for scale in inner ? [1, StageGeometry.innerScale] : [1] {
            let rect = CGRect(
                x: geometry.center.x - radii.width * scale, y: geometry.size.height - geometry.center.y - radii.height * scale,
                width: radii.width * 2 * scale, height: radii.height * 2 * scale
            )
            path.addEllipse(in: rect)
        }
        return path
    }

    /// Dots for merged deliveries; a new one falls from its node onto the trunk.
    private func dropMerged(previous: StageState, animated: Bool) {
        let fresh = Set(state.merged).subtracting(previous.merged)
        let added = trunk.show(merged: state.merged)
        guard animated, !added.isEmpty else { return }
        for id in state.merged where fresh.contains(id) {
            guard let dot = trunk.dot(for: id) else { continue }
            if reduceMotion || entries[id] == nil {
                fade(dot, from: 0, to: 1, duration: 0.3)
                continue
            }
            let drop = CABasicAnimation(keyPath: "position")
            drop.fromValue = entries[id]?.layer.position
            drop.toValue = dot.position
            drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.6)
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0.2
            appear.toValue = 1
            dot.add(CAAnimationGroup.of([drop, appear], duration: 0.8), forKey: "drop")
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0, StageGeometry(size: size) != geometry else { return }
        geometry = StageGeometry(size: size)
        CALayer.instantly {
            backdrop.frame = bounds
            linksLayer.frame = bounds
            nodesLayer.frame = bounds
            core.position = up(geometry.center)
            trunk.layout(geometry)
            let line = CATextLayer.lineHeight(CockpitStyle.ui(12))
            let below = geometry.center.y + StageGeometry.coreRadius + 36
            emptyTitle.frame = CGRect(x: 0, y: size.height - below - line / 2, width: size.width, height: line)
            emptyNote.frame = CGRect(x: 0, y: size.height - below - line / 2 - line - 2, width: size.width, height: line)
        }
        guard hasShownOnce else { return }
        slots.update(ids: state.nodes.filter { $0.auditOf == nil }.map(\.id))
        let targets = targetPositions(state.nodes)
        for node in state.nodes {
            guard let entry = entries[node.id], let target = targets[node.id] else { continue }
            entry.target = target
            place(entry, node: node, targets: targets)
        }
        refreshStatic()
        refreshMotion()
        if hovered != nil { showCard(for: hovered) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { contentsScale = scale }
    }

    private func up(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: geometry.size.height - point.y) }

    // MARK: Motion

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        refreshMotion()
    }

    /// Attaches or removes every repeating animation to match `isLive`, the
    /// motion setting and which workers run. Idempotent, and cheap: it runs on
    /// updates, a second apart at most.
    private func refreshMotion() {
        let animating = isLive && !reduceMotion
        core.setLive(animating && state.nodes.contains { $0.outcome == .running })
        for node in state.nodes {
            guard let entry = entries[node.id] else { continue }
            let running = node.outcome == .running
            entry.layer.setGlowing(animating && running)
            if running, animating {
                startParticles(entry)
            } else if running, showsStillParticles, !reduceMotion {
                placeStillParticles(entry, node: node)
            } else {
                removeParticles(entry)
            }
        }
    }

    private func makeParticles(_ entry: Entry, tint: NSColor) {
        guard entry.particles.isEmpty else { return }
        for index in 0..<Self.particlesPerLink {
            let particle = CALayer()
            let size: CGFloat = index == 0 ? 5 : 4
            particle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            particle.cornerRadius = size / 2
            particle.backgroundColor = StagePalette.light(tint, 0.5).cgColor
            particle.shadowColor = tint.cgColor
            particle.shadowOpacity = 0.9
            particle.shadowRadius = 3
            particle.shadowOffset = .zero
            particle.opacity = 0
            particle.contentsScale = contentsScale
            particle.position = entry.curve.from
            linksLayer.addSublayer(particle)
            entry.particles.append(particle)
        }
    }

    private func startParticles(_ entry: Entry) {
        guard let node = entry.layer.node else { return }
        makeParticles(entry, tint: StagePalette.tint(node.provider))
        guard entry.particles.first?.animation(forKey: "travel") == nil else { return }
        let path = entry.curve.path
        for (index, particle) in entry.particles.enumerated() {
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.95, 0.95, 0]
            fade.keyTimes = [0, 0.14, 0.82, 1]
            let group = CAAnimationGroup.of([move, fade], duration: Self.particleCycle, timing: CAMediaTimingFunction(name: .linear))
            group.repeatCount = .infinity
            group.timeOffset = Self.particleCycle * Double(index) / Double(Self.particlesPerLink)
            particle.add(group, forKey: "travel")
        }
    }

    /// For a still picture: the particles frozen at a few places along the link.
    private func placeStillParticles(_ entry: Entry, node: StageNode) {
        makeParticles(entry, tint: StagePalette.tint(node.provider))
        CALayer.instantly {
            for (index, particle) in entry.particles.enumerated() {
                particle.removeAllAnimations()
                particle.position = entry.curve.point(at: 0.28 + 0.27 * CGFloat(index))
                particle.opacity = 0.95
            }
        }
    }

    private func removeParticles(_ entry: Entry) {
        for particle in entry.particles { particle.removeFromSuperlayer() }
        entry.particles = []
    }

    /// The core's two slow breaths, for a tab that has just come up with nothing running.
    func introduce() {
        guard !reduceMotion, !isLive, state.nodes.allSatisfy({ $0.outcome != .running }) else { return }
        core.breathe(times: 2)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    private func node(at event: NSEvent) -> String? {
        let point = convert(event.locationInWindow, from: nil)
        let top = CGPoint(x: point.x, y: bounds.height - point.y)
        return StageGeometry.hit(top, in: entries.map { ($0.key, CGPoint(x: $0.value.target.x, y: $0.value.target.y), $0.value.layer.radius) })
    }

    override func mouseMoved(with event: NSEvent) {
        let id = node(at: event)
        guard id != hovered else { return }
        showCard(for: id)
        (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        showCard(for: nil)
        NSCursor.arrow.set()
    }

    override func mouseUp(with event: NSEvent) {
        if let id = node(at: event) { onSelect?(id) }
    }

    /// Shows the card of one worker, or hides it. Also how a snapshot hovers.
    func showCard(for id: String?) {
        hovered = id
        guard let id, let entry = entries[id], let node = state.nodes.first(where: { $0.id == id }) else {
            card.hide()
            return
        }
        card.show(node, now: state.now, anchor: entry.layer.position, in: bounds)
        rootLayer.setContentsScaleRecursively(contentsScale)
    }

    override var acceptsFirstResponder: Bool { false }
}

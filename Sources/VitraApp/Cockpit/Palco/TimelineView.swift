import AppKit
import QuartzCore
import VitraPanel

/// The bottom of the Palco: one swimlane per worker over a sliding window of
/// the last half hour, zoomed to the oldest run shown. Bars come from
/// `TimelineLayout`; here they are only placed, and moved a second at a time
/// by one linear animation each tick rather than redrawn.
final class TimelineView: NSView {
    private static let titleHeight: CGFloat = 26
    private static let axisHeight: CGFloat = 20
    private static let labelColumn: CGFloat = 112
    private static let gutter: CGFloat = 10
    private static let labelFont = CockpitStyle.meta
    private static let auditFont = CockpitStyle.mono(9)
    private static let axisFont = CockpitStyle.mono(9)

    var onSelect: ((String) -> Void)?
    var reduceMotion = false
    var contentsScale: CGFloat = 2 {
        didSet { rootLayer.setContentsScaleRecursively(contentsScale) }
    }
    private(set) var isLive = false

    private final class Lane {
        let label: CATextLayer
        let bar = CALayer()
        let sheen = CAGradientLayer()
        let tick = CALayer()
        var node: StageNode?
        var frame = CGRect.zero

        init(label: CATextLayer) { self.label = label }
    }

    private let rootLayer = CALayer()
    private let rule = CALayer()
    private let title = CATextLayer.line(CockpitStyle.micro, CockpitStyle.muted, alignment: .left)
    private let grid = CAShapeLayer()
    private let nowLine = CALayer()
    private let nowCap = CALayer()
    private let emptyNote = CATextLayer.line(CockpitStyle.ui(11), CockpitStyle.muted)
    private var axisLabels: [CATextLayer] = []
    private var lanes: [String: Lane] = [:]
    private var nodes: [StageNode] = []
    private var now = Date()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = rootLayer
        wantsLayer = true
        rootLayer.masksToBounds = true
        rule.backgroundColor = CockpitStyle.softLine.cgColor
        title.string = "LINHA DO TEMPO"
        grid.fillColor = nil
        grid.strokeColor = CockpitStyle.softLine.cgColor
        grid.lineWidth = 1
        nowLine.backgroundColor = CockpitStyle.accent.withAlphaComponent(0.75).cgColor
        nowCap.backgroundColor = CockpitStyle.accent.cgColor
        nowCap.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        nowCap.cornerRadius = 2.5
        emptyNote.string = "Nada rodou nos últimos 30 minutos"
        for layer in [rule, title, grid, nowLine, nowCap, emptyNote] as [CALayer] { rootLayer.addSublayer(layer) }
        rootLayer.setContentsScaleRecursively(contentsScale)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Linha do tempo dos operários")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Showing

    /// Places the lanes for `nodes` at `now`. With `glide`, everything moves
    /// to its new place over a second, in a straight line, so that a tick a
    /// second apart reads as continuous motion.
    func update(_ nodes: [StageNode], now: Date, glide: Bool) {
        self.nodes = nodes
        self.now = now
        guard bounds.width > 0 else { return }
        let layout = TimelineLayout(nodes: nodes, now: now, width: barsWidth)
        let area = CGRect(x: 0, y: Self.axisHeight, width: bounds.width, height: max(bounds.height - Self.titleHeight - Self.axisHeight, 0))
        let frames = TimelineLayout.lanes(nodes, height: area.height - 8)

        CATransaction.begin()
        if glide && !reduceMotion {
            CATransaction.setAnimationDuration(1)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        let live = Set(nodes.map(\.id))
        for (id, lane) in lanes where !live.contains(id) {
            lane.label.removeFromSuperlayer()
            lane.bar.removeFromSuperlayer()
            lanes[id] = nil
        }
        for placed in frames {
            guard let node = nodes.first(where: { $0.id == placed.id }) else { continue }
            let lane = lanes[node.id] ?? makeLane(node)
            // Top down: the first lane is the oldest run.
            let minY = area.maxY - 4 - placed.minY - placed.height
            lane.frame = CGRect(x: Self.leftEdge, y: minY, width: bounds.width - Self.leftEdge - Self.rightEdge, height: placed.height)
            paint(lane, node: node, layout: layout, height: placed.height, minY: minY)
        }
        placeGrid(layout, area: area)
        emptyNote.isHidden = !nodes.isEmpty
        emptyNote.frame = CGRect(x: 0, y: area.midY - 7, width: bounds.width, height: 16)
        CATransaction.commit()
        refreshMotion()
    }

    private static var leftEdge: CGFloat { CockpitStyle.inset + labelColumn + gutter }
    private static var rightEdge: CGFloat { CockpitStyle.inset }
    private var barsWidth: CGFloat { max(bounds.width - Self.leftEdge - Self.rightEdge, 1) }

    private func makeLane(_ node: StageNode) -> Lane {
        let font = node.isAudit ? Self.auditFont : Self.labelFont
        let label = CATextLayer.line(font, node.isAudit ? CockpitStyle.muted : CockpitStyle.code, alignment: .left)
        let lane = Lane(label: label)
        lane.sheen.startPoint = CGPoint(x: 0, y: 0.5)
        lane.sheen.endPoint = CGPoint(x: 1, y: 0.5)
        lane.sheen.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.32).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        lane.sheen.isHidden = true
        lane.sheen.actions = ["position": NSNull(), "bounds": NSNull()]
        lane.bar.masksToBounds = true
        lane.bar.addSublayer(lane.sheen)
        lane.bar.actions = ["backgroundColor": NSNull(), "borderColor": NSNull()]
        rootLayer.addSublayer(lane.bar)
        rootLayer.addSublayer(label)
        rootLayer.addSublayer(lane.tick)
        lane.bar.contentsScale = contentsScale
        label.contentsScale = contentsScale
        lanes[node.id] = lane
        // A new lane appears where it belongs, not sliding in from the corner.
        label.actions = ["position": NSNull(), "bounds": NSNull(), "string": NSNull(), "foregroundColor": NSNull()]
        return lane
    }

    private func paint(_ lane: Lane, node: StageNode, layout: TimelineLayout, height: CGFloat, minY: CGFloat) {
        let previous = lane.node
        lane.node = node
        let font = node.isAudit ? Self.auditFont : Self.labelFont
        lane.label.frame = CGRect(
            x: CockpitStyle.inset, y: minY + (height - CATextLayer.lineHeight(font)) / 2 + 0.5,
            width: Self.labelColumn, height: CATextLayer.lineHeight(font)
        )
        if previous?.label != node.label { lane.label.string = node.label }

        let bar = layout.bar(of: node, now: now)
        let tint = StagePalette.tint(node.provider)
        let fill: NSColor
        switch node.outcome {
        case .running: fill = tint.withAlphaComponent(0.8)
        case .done: fill = tint.withAlphaComponent(0.62)
        case .failed: fill = CockpitStyle.danger.withAlphaComponent(0.8)
        case .stopped: fill = CockpitStyle.muted.withAlphaComponent(0.3)
        }
        // At least a dot: a bar of a few points is not a lens.
        let barFrame = CGRect(x: Self.leftEdge + bar.minX, y: minY, width: max(bar.maxX - bar.minX, height), height: height)
        lane.bar.frame = barFrame
        lane.bar.cornerRadius = height / 2
        lane.bar.backgroundColor = fill.cgColor
        // A stopped run is outlined rather than filled, which reads as "not a result".
        lane.bar.borderWidth = node.outcome == .stopped ? 1 : 0
        lane.bar.borderColor = CockpitStyle.muted.withAlphaComponent(0.6).cgColor
        lane.bar.opacity = Float(node.emphasis * (node.isSilent ? 0.6 : 1))
        lane.label.opacity = Float(node.emphasis)

        let sheenWidth = max(min(barFrame.width, 70), 1)
        lane.sheen.frame = CGRect(x: 0, y: 0, width: sheenWidth, height: height)
        lane.sheen.isHidden = node.outcome != .running

        if let score = node.score {
            lane.tick.isHidden = false
            lane.tick.backgroundColor = StagePalette.rating(score).cgColor
            lane.tick.frame = CGRect(x: barFrame.maxX + 1, y: minY - 2, width: 2, height: height + 4)
        } else {
            lane.tick.isHidden = true
        }
    }

    private func placeGrid(_ layout: TimelineLayout, area: CGRect) {
        // With nothing to show, the axis would only be noise.
        let lines = nodes.isEmpty ? [] : layout.lines()
        nowLine.isHidden = nodes.isEmpty
        nowCap.isHidden = nodes.isEmpty
        let path = CGMutablePath()
        for line in lines {
            let x = Self.leftEdge + line.x
            path.move(to: CGPoint(x: x, y: area.minY))
            path.addLine(to: CGPoint(x: x, y: area.maxY))
        }
        grid.frame = bounds
        grid.path = path
        while axisLabels.count < lines.count {
            let label = CATextLayer.line(Self.axisFont, CockpitStyle.muted)
            label.contentsScale = contentsScale
            axisLabels.append(label)
            rootLayer.addSublayer(label)
        }
        for (index, label) in axisLabels.enumerated() {
            guard index < lines.count else {
                label.isHidden = true
                continue
            }
            let line = lines[index]
            label.isHidden = false
            if label.string as? String != line.label { label.string = line.label }
            label.frame = CGRect(x: Self.leftEdge + line.x - 22, y: 4, width: 44, height: CATextLayer.lineHeight(Self.axisFont))
        }
        let nowX = Self.leftEdge + layout.x(now)
        nowLine.frame = CGRect(x: nowX - 0.5, y: area.minY - 2, width: 1, height: area.height + 2)
        nowCap.position = CGPoint(x: nowX, y: area.minY - 2)
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        title.frame = CGRect(x: CockpitStyle.inset, y: bounds.height - Self.titleHeight + 6, width: 200, height: CATextLayer.lineHeight(CockpitStyle.micro))
    }

    override func layout() {
        super.layout()
        update(nodes, now: now, glide: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { contentsScale = scale }
    }

    // MARK: Motion

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        refreshMotion()
    }

    /// The sheen that slides along a running bar, only while live.
    private func refreshMotion() {
        for lane in lanes.values {
            let running = lane.node?.outcome == .running
            guard isLive, running, !reduceMotion else {
                lane.sheen.removeAnimation(forKey: "slide")
                continue
            }
            guard lane.sheen.animation(forKey: "slide") == nil else { continue }
            let width = max(lane.bar.bounds.width, 1)
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -lane.sheen.bounds.width / 2
            slide.toValue = width + lane.sheen.bounds.width / 2
            slide.duration = 2.4
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            lane.sheen.add(slide, forKey: "slide")
        }
    }

    // MARK: Pointer

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = lanes.first { ($0.value.frame.minY - 2 ... $0.value.frame.maxY + 2).contains(point.y) }
        if let id = hit?.key { onSelect?(id) }
    }
}

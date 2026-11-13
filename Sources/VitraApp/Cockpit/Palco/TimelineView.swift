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
    /// Lanes this tall or taller carry their name over the bar, at full
    /// width; shorter ones (many workers at once) put a column of names
    /// beside the bars instead.
    private static let roomyLane: CGFloat = 24
    private static let compactLabelColumn: CGFloat = 150
    private static let stateColumn: CGFloat = 96
    private static let gutter: CGFloat = 10
    private static let dotSize: CGFloat = 6
    /// Where the bars start: the content inset, or past the names when compact.
    private var leftEdge: CGFloat = CockpitStyle.inset
    private static let labelFont = CockpitStyle.caption
    private static let auditFont = CockpitStyle.ui(10)
    private static let axisFont = CockpitStyle.mono(9)
    /// How far a bar may grow before its sheen's sweep is rebuilt to span it.
    private static let sweepSlack: CGFloat = 4

    var onSelect: ((String) -> Void)?
    var reduceMotion = false
    var contentsScale: CGFloat = 2 {
        didSet { rootLayer.setContentsScaleRecursively(contentsScale) }
    }
    private(set) var isLive = false

    private final class Lane {
        let label: CATextLayer
        /// What became of it, at the right: how long it has run, or "pronto 5/5".
        let state = CATextLayer.line(CockpitStyle.meta, CockpitStyle.muted, alignment: .right)
        /// The provider's tint, so the bar's colour is free to say the outcome.
        let dot = CALayer()
        let bar = CALayer()
        let sheen = CAGradientLayer()
        let tick = CALayer()
        var node: StageNode?
        var frame = CGRect.zero
        /// The bar width the running sweep was built for.
        var sweptWidth: CGFloat = 0

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
        let area = CGRect(x: 0, y: Self.axisHeight, width: bounds.width, height: max(bounds.height - Self.titleHeight - Self.axisHeight, 0))
        let frames = TimelineLayout.lanes(nodes, height: area.height - 8, preferredRow: 30, gap: 8)
        let isCompact = (frames.first { !$0.isAudit }?.height ?? Self.roomyLane) < Self.roomyLane
        leftEdge = CockpitStyle.inset + (isCompact ? Self.compactLabelColumn + Self.gutter : 0)
        let layout = TimelineLayout(nodes: nodes, now: now, width: barsWidth)

        CATransaction.begin()
        if glide && !reduceMotion {
            CATransaction.setAnimationDuration(1)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        let live = Set(nodes.map(\.id))
        for (id, lane) in lanes where !live.contains(id) {
            // Every layer of it: a rating tick left behind is a green mark
            // floating over nothing.
            for layer in [lane.label, lane.state, lane.dot, lane.bar, lane.tick] { layer.removeFromSuperlayer() }
            lanes[id] = nil
        }
        for placed in frames {
            guard let node = nodes.first(where: { $0.id == placed.id }) else { continue }
            let lane = lanes[node.id] ?? makeLane(node)
            // Top down: the first lane is the oldest run.
            let minY = area.maxY - 4 - placed.minY - placed.height
            lane.frame = CGRect(x: leftEdge, y: minY, width: bounds.width - leftEdge - Self.rightEdge, height: placed.height)
            paint(lane, node: node, layout: layout, height: placed.height, minY: minY, isCompact: isCompact)
        }
        placeGrid(layout, area: area)
        emptyNote.isHidden = !nodes.isEmpty
        emptyNote.frame = CGRect(x: 0, y: area.midY - 7, width: bounds.width, height: 16)
        CATransaction.commit()
        refreshMotion()
    }

    private static var rightEdge: CGFloat { CockpitStyle.inset }
    private var barsWidth: CGFloat { max(bounds.width - leftEdge - Self.rightEdge, 1) }

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
        rootLayer.addSublayer(lane.state)
        rootLayer.addSublayer(lane.dot)
        lane.tick.isHidden = true
        lane.state.contentsScale = contentsScale
        lane.dot.cornerRadius = Self.dotSize / 2
        lane.dot.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        lane.bar.contentsScale = contentsScale
        label.contentsScale = contentsScale
        lanes[node.id] = lane
        // A new lane appears where it belongs, not sliding in from the corner.
        label.actions = ["position": NSNull(), "bounds": NSNull(), "string": NSNull(), "foregroundColor": NSNull()]
        return lane
    }

    /// The name a lane carries: what was asked, and of whom.
    private static func caption(_ node: StageNode) -> String {
        let worker = node.model + (node.effort.map { " (\($0))" } ?? "")
        return (node.isAudit ? "↳ auditoria" : node.label) + "  ·  " + worker
    }

    private func paint(_ lane: Lane, node: StageNode, layout: TimelineLayout, height: CGFloat, minY: CGFloat, isCompact: Bool) {
        let previous = lane.node
        lane.node = node
        let font = node.isAudit ? Self.auditFont : Self.labelFont
        let textHeight = CATextLayer.lineHeight(font)
        // The outcome is the colour: amber at work, green delivered, red failed.
        let colour: NSColor
        switch node.outcome {
        case .running: colour = CockpitStyle.accent
        case .done: colour = StagePalette.rating(node.score ?? 5)
        case .failed: colour = CockpitStyle.danger
        case .stopped: colour = CockpitStyle.muted
        }

        // Roomy: the name runs the full width over a thin bar. Compact: the
        // name sits in a column at the left, centred on its bar.
        let indent: CGFloat = node.isAudit ? 14 : 0
        let textY = isCompact ? minY + (height - textHeight) / 2 + 0.5 : minY + height - textHeight
        let textX = CockpitStyle.inset + indent + Self.dotSize + 6
        let textWidth = isCompact
            ? Self.compactLabelColumn - indent - Self.dotSize - 6
            : bounds.width - 2 * CockpitStyle.inset - indent - Self.dotSize - 6 - Self.stateColumn
        lane.label.frame = CGRect(x: textX, y: textY, width: max(textWidth, 20), height: textHeight)
        let caption = isCompact ? (node.isAudit ? "↳ auditoria" : node.label) : Self.caption(node)
        if lane.label.string as? String != caption { lane.label.string = caption }
        lane.dot.backgroundColor = StagePalette.tint(node.provider).cgColor
        lane.dot.frame = CGRect(
            x: CockpitStyle.inset + indent, y: textY + (textHeight - Self.dotSize) / 2,
            width: Self.dotSize, height: Self.dotSize
        )
        if previous?.stateText != node.stateText { lane.state.string = node.stateText }
        lane.state.foregroundColor = colour.cgColor

        let bar = layout.bar(of: node, now: now)
        let barHeight: CGFloat = isCompact ? height : (node.isAudit ? 3 : 6)
        // At least a dot: a bar of a few points is not a lens.
        let barFrame = CGRect(x: leftEdge + bar.minX, y: minY, width: max(bar.maxX - bar.minX, barHeight), height: barHeight)
        lane.bar.frame = barFrame
        lane.bar.cornerRadius = barHeight / 2
        lane.bar.backgroundColor = colour.withAlphaComponent(node.outcome == .stopped ? 0.25 : 0.85).cgColor
        // A stopped run is outlined rather than filled, which reads as "not a result".
        lane.bar.borderWidth = node.outcome == .stopped ? 1 : 0
        lane.bar.borderColor = CockpitStyle.muted.withAlphaComponent(0.6).cgColor
        // What became of it: at the right of the name when roomy; when
        // compact, beside its bar — after it, or before when the bar ends at "now".
        let stateHeight = CATextLayer.lineHeight(CockpitStyle.meta)
        if isCompact {
            let fitsAfter = bounds.width - CockpitStyle.inset - barFrame.maxX >= Self.stateColumn * 0.7
            lane.state.alignmentMode = fitsAfter ? .left : .right
            lane.state.frame = CGRect(
                x: fitsAfter ? barFrame.maxX + 6 : barFrame.minX - 6 - Self.stateColumn,
                y: minY + (height - stateHeight) / 2 + 0.5, width: Self.stateColumn, height: stateHeight
            )
        } else {
            lane.state.alignmentMode = .right
            lane.state.frame = CGRect(
                x: bounds.width - CockpitStyle.inset - Self.stateColumn, y: textY,
                width: Self.stateColumn, height: stateHeight
            )
        }
        let emphasis = Float(node.emphasis * (node.isSilent ? 0.6 : 1))
        lane.bar.opacity = emphasis
        lane.label.opacity = Float(node.emphasis)
        lane.state.opacity = Float(node.emphasis)
        lane.dot.opacity = Float(node.emphasis)

        let sheenWidth = max(min(barFrame.width, 70), 1)
        lane.sheen.frame = CGRect(x: 0, y: 0, width: sheenWidth, height: barHeight)
        // With Reduce Motion there is no sheen at all, moving or not.
        lane.sheen.isHidden = node.outcome != .running || reduceMotion
    }

    private func placeGrid(_ layout: TimelineLayout, area: CGRect) {
        // With nothing to show, the axis would only be noise.
        let lines = nodes.isEmpty ? [] : layout.lines()
        nowLine.isHidden = nodes.isEmpty
        nowCap.isHidden = nodes.isEmpty
        let path = CGMutablePath()
        for line in lines {
            let x = leftEdge + line.x
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
            label.frame = CGRect(x: leftEdge + line.x - 22, y: 4, width: 44, height: CATextLayer.lineHeight(Self.axisFont))
        }
        let nowX = leftEdge + layout.x(now)
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
            // The bar grows for as long as the run goes on: the sweep is
            // rebuilt whenever it spans a width a few points off the bar's.
            let width = max(lane.bar.bounds.width, 1)
            if lane.sheen.animation(forKey: "slide") != nil, abs(width - lane.sweptWidth) <= Self.sweepSlack { continue }
            lane.sweptWidth = width
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

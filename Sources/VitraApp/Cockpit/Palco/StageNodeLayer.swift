import AppKit
import QuartzCore
import VitraPanel

/// The colours the Palco reads from the theme.
enum StagePalette {
    static func tint(_ provider: StageProvider) -> NSColor {
        switch provider {
        case .claude: return CockpitStyle.providerClaude
        case .opencode: return CockpitStyle.providerOpencode
        case .cursor: return CockpitStyle.providerCursor
        case .gemini: return CockpitStyle.providerGemini
        }
    }

    /// What a finished worker settles into; a running one keeps its provider's tint.
    static func state(_ node: StageNode) -> NSColor {
        switch node.outcome {
        case .running: return tint(node.provider)
        case .done: return CockpitStyle.success
        case .failed: return CockpitStyle.danger
        case .stopped: return CockpitStyle.muted
        }
    }

    static func stateText(_ node: StageNode) -> NSColor {
        switch node.outcome {
        case .running: return CockpitStyle.muted
        case .done: return CockpitStyle.success
        case .failed: return CockpitStyle.dangerText
        case .stopped: return CockpitStyle.muted
        }
    }

    /// `color` lifted toward the text colour, for a glyph or a light particle.
    static func light(_ color: NSColor, _ amount: CGFloat = 0.45) -> NSColor {
        color.blended(withFraction: amount, of: CockpitStyle.text) ?? color
    }

    static func rating(_ score: Int) -> NSColor {
        score >= 4 ? CockpitStyle.success : (score == 3 ? CockpitStyle.accent : CockpitStyle.danger)
    }
}

extension CATextLayer {
    /// A single line of text that is cut with an ellipsis rather than wrapped.
    static func line(_ font: NSFont, _ color: NSColor, alignment: CATextLayerAlignmentMode = .center) -> CATextLayer {
        let layer = CATextLayer()
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        layer.alignmentMode = alignment
        layer.truncationMode = .end
        layer.isWrapped = false
        layer.actions = ["contents": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }

    /// The height a line of `font` needs.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 1
    }
}

extension CAAnimationGroup {
    /// `animations` played together for `duration`: each member is given the
    /// group's length, which a group does not do for them.
    static func of(_ animations: [CAAnimation], duration: CFTimeInterval, timing: CAMediaTimingFunction? = nil) -> CAAnimationGroup {
        animations.forEach { $0.duration = duration }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = timing
        return group
    }
}

extension CALayer {
    /// Changes layers' properties with no implicit animation.
    static func instantly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Sets the contents scale of this layer and everything under it, so that
    /// text is drawn at the screen's resolution: only a view's own layer gets
    /// that for free.
    func setContentsScaleRecursively(_ scale: CGFloat) {
        contentsScale = scale
        sublayers?.forEach { $0.setContentsScaleRecursively(scale) }
    }
}

/// One worker on the stage: a disc in its provider's tint, a ring that fills
/// as its time allowance is used, the model's mark, and under it the run's
/// label, its state and its rating. Built once per run and updated in place.
///
/// Coordinates are y-up (the layer's own), with the disc at the layer's bounds
/// and the text hanging below it.
final class StageNodeLayer: CALayer {
    static let labelWidth: CGFloat = 84
    private static let ringWidth: CGFloat = 2.5
    private static let dotSize: CGFloat = 4
    private static var labelFont: NSFont { CockpitStyle.ui(10, .medium) }
    private static var stateFont: NSFont { CockpitStyle.mono(9.5, .medium) }
    private static var glyphFont: NSFont { CockpitStyle.ui(11, .semibold) }

    let radius: CGFloat
    let isAudit: Bool
    private(set) var node: StageNode?

    private let halo = CAShapeLayer()
    private let disc = CAShapeLayer()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let glyph = CATextLayer.line(StageNodeLayer.glyphFont, CockpitStyle.text)
    private let label = CATextLayer.line(StageNodeLayer.labelFont, CockpitStyle.text)
    private let state = CATextLayer.line(StageNodeLayer.stateFont, CockpitStyle.muted)
    private var dots: [CALayer] = []

    init(radius: CGFloat, isAudit: Bool) {
        self.radius = radius
        self.isAudit = isAudit
        super.init()
        bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        build()
    }

    override init(layer: Any) {
        let other = layer as? StageNodeLayer
        radius = other?.radius ?? 0
        isAudit = other?.isAudit ?? false
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let box = bounds
        let circle = CGPath(ellipseIn: box.insetBy(dx: Self.ringWidth / 2, dy: Self.ringWidth / 2), transform: nil)
        // From the top, clockwise on screen.
        let arc = CGMutablePath()
        let centre = CGPoint(x: box.midX, y: box.midY)
        arc.addArc(center: centre, radius: radius - Self.ringWidth / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)

        halo.frame = box
        halo.path = CGPath(ellipseIn: box.insetBy(dx: 2, dy: 2), transform: nil)
        halo.fillColor = NSColor.clear.cgColor
        halo.shadowOffset = .zero
        halo.shadowRadius = radius * 0.7
        halo.shadowOpacity = 0

        disc.frame = box
        disc.path = CGPath(ellipseIn: box.insetBy(dx: Self.ringWidth + 1, dy: Self.ringWidth + 1), transform: nil)
        for shape in [track, ring] {
            shape.frame = box
            shape.fillColor = nil
            shape.lineWidth = Self.ringWidth
            shape.lineCap = .round
        }
        track.path = circle
        track.strokeColor = CockpitStyle.raisedLine.cgColor
        ring.path = arc
        ring.strokeEnd = 0
        ring.actions = ["strokeEnd": NSNull(), "strokeColor": NSNull()]

        glyph.font = Self.glyphFont
        glyph.fontSize = isAudit ? 8 : Self.glyphFont.pointSize
        glyph.frame = CGRect(x: 0, y: box.midY - CATextLayer.lineHeight(Self.glyphFont) / 2 + 0.5, width: box.width, height: CATextLayer.lineHeight(Self.glyphFont))
        for layer in [halo, disc, track, ring, glyph] { addSublayer(layer) }

        guard !isAudit else { return }
        let labelHeight = CATextLayer.lineHeight(Self.labelFont)
        let stateHeight = CATextLayer.lineHeight(Self.stateFont)
        let left = box.midX - Self.labelWidth / 2
        label.frame = CGRect(x: left, y: -labelHeight - 3, width: Self.labelWidth, height: labelHeight)
        state.frame = CGRect(x: left, y: label.frame.minY - stateHeight + 1, width: Self.labelWidth, height: stateHeight)
        addSublayer(label)
        addSublayer(state)
        for index in 0..<5 {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            dot.cornerRadius = Self.dotSize / 2
            dot.position = CGPoint(x: box.midX + CGFloat(index - 2) * (Self.dotSize + 3), y: state.frame.minY - Self.dotSize / 2 - 2)
            dot.isHidden = true
            dots.append(dot)
            addSublayer(dot)
        }
    }

    // MARK: Showing a node

    /// Paints the node as it is now. Writes only what changed: this runs once a second.
    func apply(_ node: StageNode) {
        let previous = self.node
        self.node = node
        CALayer.instantly {
            let tint = StagePalette.tint(node.provider)
            let stateColor = StagePalette.state(node)
            if previous?.provider != node.provider {
                disc.fillColor = tint.withAlphaComponent(0.2).cgColor
                disc.strokeColor = tint.withAlphaComponent(0.5).cgColor
                glyph.foregroundColor = StagePalette.light(tint, 0.5).cgColor
                halo.shadowColor = tint.cgColor
            }
            if previous?.outcome != node.outcome {
                ring.strokeColor = stateColor.cgColor
                state.foregroundColor = StagePalette.stateText(node).cgColor
                halo.shadowColor = stateColor.cgColor
            }
            if previous?.glyph != node.glyph { glyph.string = node.glyph }
            if previous?.label != node.label { label.string = node.label }
            if previous?.stateText != node.stateText { state.string = node.stateText }
            if previous?.deadlineFraction != node.deadlineFraction { ring.strokeEnd = max(CGFloat(node.deadlineFraction), 0.012) }
            if previous?.score != node.score { showScore(node.score) }
            opacity = Float(node.emphasis * (node.isSilent ? 0.55 : 1))
            // A settled worker has no glow of its own.
            if node.outcome != .running { halo.shadowOpacity = 0 }
        }
    }

    private func showScore(_ score: Int?) {
        for (index, dot) in dots.enumerated() {
            dot.isHidden = score == nil
            guard let score else { continue }
            dot.backgroundColor = (index < score ? StagePalette.rating(score) : CockpitStyle.raisedLine).cgColor
        }
    }

    // MARK: Motion

    /// The ring's gentle glow while the worker runs; off otherwise.
    func setGlowing(_ glowing: Bool) {
        guard glowing, node?.outcome == .running else {
            halo.removeAnimation(forKey: "glow")
            return
        }
        guard halo.animation(forKey: "glow") == nil else { return }
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0.15
        glow.toValue = 0.75
        glow.duration = 1.7
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.shadowOpacity = 0.45
        halo.add(glow, forKey: "glow")
    }

    /// A short ring of light that spreads and fades: the five-out-of-five sparkle.
    func sparkle(animated: Bool) {
        guard !isAudit else { return }
        let burst = CAShapeLayer()
        burst.frame = bounds
        burst.path = CGPath(ellipseIn: bounds, transform: nil)
        burst.fillColor = nil
        burst.strokeColor = CockpitStyle.success.cgColor
        burst.lineWidth = 1.5
        burst.opacity = 0
        insertSublayer(burst, above: ring)
        guard animated else {
            burst.removeFromSuperlayer()
            return
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2.1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.9, 0]
        CATransaction.begin()
        CATransaction.setCompletionBlock { burst.removeFromSuperlayer() }
        burst.add(CAAnimationGroup.of([scale, fade], duration: 0.9, timing: CAMediaTimingFunction(name: .easeOut)), forKey: "sparkle")
        CATransaction.commit()
    }

    /// Where the disc's centre sits, for a particle to start from or arrive at.
    var centre: CGPoint { position }
}

import AppKit
import QuartzCore
import VitraPanel

/// The maestro at the stage's centre: a disc with its model's name, a thin arc
/// for the week's usage, and an outer ring of dashes that turns while workers run.
/// Y-up, centred on its own bounds.
final class StageCoreLayer: CALayer {
    static let radius = StageGeometry.coreRadius
    private static let usageRadius = radius + 8
    private static let spinRadius = radius + 17
    private static let extent = (radius + 34) * 2
    private static var titleFont: NSFont { CockpitStyle.ui(12, .semibold) }
    private static var smallFont: NSFont { CockpitStyle.mono(9, .medium) }

    private let glow = CAGradientLayer()
    private let body = CALayer()
    private let disc = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let usageTrack = CAShapeLayer()
    private let usageArc = CAShapeLayer()
    private let spin = CAShapeLayer()
    private let title = CATextLayer.line(StageCoreLayer.titleFont, CockpitStyle.text)
    private let effort = CATextLayer.line(StageCoreLayer.smallFont, CockpitStyle.muted)
    private let week = CATextLayer.line(StageCoreLayer.smallFont, CockpitStyle.muted)

    override init() {
        super.init()
        let box = CGRect(x: 0, y: 0, width: Self.extent, height: Self.extent)
        let mid = CGPoint(x: box.midX, y: box.midY)
        bounds = box

        glow.frame = box
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [CockpitStyle.accent.withAlphaComponent(0.22).cgColor, CockpitStyle.accent.withAlphaComponent(0).cgColor]
        glow.locations = [0.35, 1]

        // The disc and what is on it breathe together.
        body.frame = box
        disc.frame = box
        disc.path = CGPath(ellipseIn: CGRect(x: mid.x - Self.radius, y: mid.y - Self.radius, width: 2 * Self.radius, height: 2 * Self.radius), transform: nil)
        disc.fillColor = CockpitStyle.raised.cgColor
        disc.strokeColor = CockpitStyle.accent.withAlphaComponent(0.45).cgColor
        disc.lineWidth = 1

        sheen.frame = box
        sheen.type = .radial
        sheen.startPoint = CGPoint(x: 0.5, y: 0.62)
        sheen.endPoint = CGPoint(x: 0.5 + Self.radius / box.width, y: 0.62 + Self.radius / box.height)
        sheen.colors = [CockpitStyle.accent.withAlphaComponent(0.2).cgColor, CockpitStyle.accent.withAlphaComponent(0).cgColor]
        let clip = CAShapeLayer()
        clip.path = disc.path
        sheen.mask = clip

        let ring = CGMutablePath()
        ring.addArc(center: mid, radius: Self.usageRadius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [usageTrack, usageArc] {
            shape.frame = box
            shape.path = ring
            shape.fillColor = nil
            shape.lineWidth = 2.5
            shape.lineCap = .round
        }
        usageTrack.strokeColor = CockpitStyle.raisedLine.cgColor
        usageArc.strokeColor = CockpitStyle.accent.cgColor
        usageArc.strokeEnd = 0
        usageArc.actions = ["strokeEnd": NSNull(), "strokeColor": NSNull()]

        spin.bounds = box
        spin.position = mid
        spin.path = CGPath(ellipseIn: CGRect(x: mid.x - Self.spinRadius, y: mid.y - Self.spinRadius, width: 2 * Self.spinRadius, height: 2 * Self.spinRadius), transform: nil)
        spin.fillColor = nil
        spin.strokeColor = CockpitStyle.accent.withAlphaComponent(0.4).cgColor
        spin.lineWidth = 2
        spin.lineCap = .round
        spin.lineDashPattern = [0.5, 7]

        let lines: [(CATextLayer, CGFloat)] = [(title, 9), (effort, -3), (week, -14)]
        for (layer, offset) in lines {
            let height = CATextLayer.lineHeight(layer.font as? NSFont ?? Self.titleFont)
            layer.frame = CGRect(x: mid.x - Self.radius + 2, y: mid.y + offset - height / 2, width: 2 * Self.radius - 4, height: height)
        }
        for layer in [glow, body, spin, usageTrack, usageArc] { addSublayer(layer) }
        for layer in [disc, sheen, title, effort, week] as [CALayer] { body.addSublayer(layer) }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Writes the maestro's model and the week's usage on the core.
    func configure(title name: String, effort level: String?, week percent: Double?) {
        CALayer.instantly {
            title.string = name
            effort.string = level
            week.string = percent.map { "semana \(Int($0.rounded()))%" }
            let fraction = CGFloat((percent ?? 0) / 100)
            usageArc.strokeEnd = percent == nil ? 0 : max(fraction, 0.01)
            let colour = (percent ?? 0) >= 90 ? CockpitStyle.danger : CockpitStyle.accent
            usageArc.strokeColor = colour.cgColor
            // Without an effort, the name sits a little lower, centred on the disc.
            title.frame.origin.y = (effort.string == nil && week.string == nil ? bounds.midY : bounds.midY + 9) - title.frame.height / 2
        }
    }

    // MARK: Motion

    /// The breathing and the turning ring, on while workers run; off otherwise.
    func setLive(_ live: Bool) {
        guard live else {
            body.removeAnimation(forKey: "breath")
            glow.removeAnimation(forKey: "breath")
            spin.removeAnimation(forKey: "turn")
            return
        }
        if body.animation(forKey: "breath") == nil { breathe(times: .infinity) }
        guard spin.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 36
        turn.repeatCount = .infinity
        spin.add(turn, forKey: "turn")
    }

    /// The empty stage's slow breath: one scale animation, played by the
    /// render server for as long as it is attached, so the app itself stays idle.
    func setIdleBreathing(_ on: Bool) {
        guard on else {
            body.removeAnimation(forKey: "idle")
            return
        }
        guard body.animation(forKey: "idle") == nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.035
        grow.duration = 4.2
        grow.autoreverses = true
        grow.repeatCount = .infinity
        grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(grow, forKey: "idle")
    }

    /// The breathing while workers run.
    func breathe(times: Float) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.045
        grow.duration = 2.6
        grow.autoreverses = true
        grow.repeatCount = times
        grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(grow, forKey: "breath")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.6
        pulse.toValue = 1
        pulse.duration = 2.6
        pulse.autoreverses = true
        pulse.repeatCount = times
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "breath")
    }

    /// A ring of amber that spreads from the disc: a delivery arrived.
    func absorb() {
        let ripple = CAShapeLayer()
        let box = bounds
        ripple.frame = box
        ripple.path = CGPath(ellipseIn: CGRect(x: box.midX - Self.radius, y: box.midY - Self.radius, width: 2 * Self.radius, height: 2 * Self.radius), transform: nil)
        ripple.fillColor = nil
        ripple.strokeColor = CockpitStyle.accent.cgColor
        ripple.lineWidth = 1.5
        ripple.opacity = 0
        insertSublayer(ripple, below: body)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.5
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.7, 0]
        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        ripple.add(CAAnimationGroup.of([scale, fade], duration: 1, timing: CAMediaTimingFunction(name: .easeOut)), forKey: "absorb")
        CATransaction.commit()
    }
}

import AppKit

/// Vitra's mark, drawn live in the theme's colours: the cockpit's stage read
/// as a V. One amber core low in the middle — the maestro — two beams rising
/// to two workers on its orbit, and other workers, in their providers' tints,
/// on the rings. The same geometry as the app icon (scripts/make-icon.swift),
/// on a round plate instead of the icon's tile.
///
/// Core Graphics in `draw(_:)`, not image assets: it scales to any size
/// crisply, follows the theme, and draws in the snapshot tool as it does on
/// screen.
final class VitraMark: NSView {
    // The icon's canvas: 1024 wide, y upwards, the art on 100…924.
    private static let canvas: CGFloat = 1024
    private static let centre = CGPoint(x: 512, y: 512)
    private static let plateRadius: CGFloat = 412
    private static let vertex = CGPoint(x: 512, y: 318)
    private static let leftTip = CGPoint(x: 322, y: 706)
    private static let rightTip = CGPoint(x: 702, y: 706)

    /// Points per canvas unit, for the drawing in progress.
    private var unit: CGFloat = 1

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 120) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        context.saveGState()
        context.translateBy(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
        context.scaleBy(x: side / Self.canvas, y: side / Self.canvas)
        // Shadows are not scaled by the transform: their blur is given in
        // the view's points, so the canvas's figures are brought down to them.
        unit = side / Self.canvas
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawPlate(in: context)
        drawOrbits(in: context)
        drawBeams(in: context)
        drawNodes(in: context)
        context.restoreGState()
    }

    private static func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func gradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map(\.0.cgColor) as CFArray,
            locations: stops.map(\.1)
        )
    }

    /// The round plate: raised graphite, lit by the core from below, with a
    /// hairline rim.
    private func drawPlate(in context: CGContext) {
        let plate = Self.circle(Self.centre, Self.plateRadius)
        context.saveGState()
        context.addEllipse(in: plate)
        context.clip()
        if let ground = Self.gradient([(CockpitStyle.tab, 0), (CockpitStyle.panel, 1)]) {
            context.drawLinearGradient(ground, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        }
        let accent = CockpitStyle.accent
        if let glow = Self.gradient([(accent.withAlphaComponent(0.30), 0), (accent.withAlphaComponent(0.08), 0.45), (accent.withAlphaComponent(0), 1)]) {
            context.drawRadialGradient(glow, startCenter: Self.vertex, startRadius: 0, endCenter: Self.vertex, endRadius: 470, options: [])
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(6)
        context.strokeEllipse(in: plate.insetBy(dx: 3, dy: 3))
    }

    /// The two orbits around the core, kept inside the plate, and the workers
    /// travelling them in their providers' tints.
    private func drawOrbits(in context: CGContext) {
        let outer = hypot(Self.leftTip.x - Self.vertex.x, Self.leftTip.y - Self.vertex.y)
        let inner = outer * 0.58
        context.saveGState()
        context.addEllipse(in: Self.circle(Self.centre, Self.plateRadius - 6))
        context.clip()
        context.setLineWidth(6)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        context.strokeEllipse(in: Self.circle(Self.vertex, outer))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
        context.strokeEllipse(in: Self.circle(Self.vertex, inner))

        let others: [(radius: CGFloat, degrees: CGFloat, tint: NSColor, size: CGFloat)] = [
            (outer, 90, CockpitStyle.providerOpencode, 30),
            (inner, 158, CockpitStyle.providerGemini, 24),
            (inner, 36, CockpitStyle.success, 20),
        ]
        for other in others {
            let angle = other.degrees * .pi / 180
            let centre = CGPoint(x: Self.vertex.x + cos(angle) * other.radius, y: Self.vertex.y + sin(angle) * other.radius)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 26 * unit, color: other.tint.withAlphaComponent(0.7).cgColor)
            context.setFillColor(other.tint.cgColor)
            context.fillEllipse(in: Self.circle(centre, other.size))
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Maestro to workers: bright at the workers, warming towards the core.
    private func drawBeams(in context: CGContext) {
        let width: CGFloat = 58
        let beams = CGMutablePath()
        beams.move(to: Self.leftTip)
        beams.addLine(to: Self.vertex)
        beams.addLine(to: Self.rightTip)
        context.saveGState()
        context.addPath(beams)
        context.setLineWidth(width)
        context.replacePathWithStrokedPath()
        context.clip()
        let warm = CockpitStyle.text.blended(withFraction: 0.45, of: CockpitStyle.accent) ?? CockpitStyle.accent
        if let light = Self.gradient([(CockpitStyle.text, 0), (CockpitStyle.text, 0.55), (warm, 1)]) {
            context.drawLinearGradient(
                light,
                start: CGPoint(x: 512, y: Self.leftTip.y + width / 2),
                end: CGPoint(x: 512, y: Self.vertex.y - width / 2),
                options: []
            )
        }
        context.restoreGState()
    }

    /// The two workers at the beams' tips, and the maestro with its glow and
    /// the ring the stage draws round a maestro at work.
    private func drawNodes(in context: CGContext) {
        for tip in [Self.leftTip, Self.rightTip] {
            context.setFillColor(CockpitStyle.text.cgColor)
            context.fillEllipse(in: Self.circle(tip, 54))
        }
        let accent = CockpitStyle.accent
        let core: CGFloat = 92
        context.saveGState()
        context.setShadow(offset: .zero, blur: 70 * unit, color: accent.withAlphaComponent(0.9).cgColor)
        context.setFillColor(accent.cgColor)
        context.fillEllipse(in: Self.circle(Self.vertex, core))
        context.restoreGState()

        // Lit from above, like the rest of the plate.
        context.saveGState()
        context.addEllipse(in: Self.circle(Self.vertex, core))
        context.clip()
        let highlight = NSColor(srgbRed: 1, green: 0.886, blue: 0.659, alpha: 0.9)
        if let shine = Self.gradient([(highlight, 0), (accent.withAlphaComponent(0.4), 0.55), (accent.withAlphaComponent(0), 1)]) {
            context.drawRadialGradient(
                shine,
                startCenter: CGPoint(x: Self.vertex.x - 22, y: Self.vertex.y + 30), startRadius: 0,
                endCenter: Self.vertex, endRadius: core * 1.15,
                options: []
            )
        }
        context.restoreGState()

        context.setStrokeColor(CockpitStyle.ground.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(10)
        context.strokeEllipse(in: Self.circle(Self.vertex, core + 5))
        context.setStrokeColor(accent.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(6)
        context.strokeEllipse(in: Self.circle(Self.vertex, core + 34))
    }
}

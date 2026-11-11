import AppKit
import QuartzCore
import VitraPanel

/// The branch drawn as a horizontal trunk along the bottom of the stage, with
/// its name, and a dot for each of the last few deliveries merged into it.
/// Y-up; laid out for a stage of a given size.
final class StageTrunkLayer: CALayer {
    private static var font: NSFont { CockpitStyle.mono(10, .medium) }
    private static let dotSize: CGFloat = 8

    private let line = CAShapeLayer()
    private let origin = CAShapeLayer()
    private let caption = CATextLayer.line(StageTrunkLayer.font, CockpitStyle.muted, alignment: .left)
    private var dots: [String: CALayer] = [:]
    private var order: [String] = []
    private var geometry = StageGeometry(size: .zero)

    override init() {
        super.init()
        line.fillColor = nil
        line.strokeColor = CockpitStyle.raisedLine.cgColor
        line.lineWidth = 2
        line.lineCap = .round
        origin.fillColor = CockpitStyle.raisedLine.cgColor
        origin.strokeColor = CockpitStyle.controlLine.cgColor
        origin.lineWidth = 1
        caption.string = "main"
        for layer in [line, origin, caption] { addSublayer(layer) }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setBranch(_ branch: String?) {
        CALayer.instantly { caption.string = branch ?? "main" }
    }

    /// Where the dot that will be the newest sits, in the stage's y-up layer.
    func newestDotPosition() -> CGPoint { up(geometry.commitPosition(index: 0)) }

    func layout(_ geometry: StageGeometry) {
        self.geometry = geometry
        let height = geometry.size.height
        CALayer.instantly {
            frame = CGRect(origin: .zero, size: geometry.size)
            let y = height - geometry.trunkY
            let path = CGMutablePath()
            path.move(to: CGPoint(x: StageGeometry.trunkInset, y: y))
            path.addLine(to: CGPoint(x: geometry.size.width - StageGeometry.trunkInset, y: y))
            line.frame = bounds
            line.path = path
            origin.frame = bounds
            origin.path = CGPath(ellipseIn: CGRect(x: StageGeometry.trunkInset - 4, y: y - 4, width: 8, height: 8), transform: nil)
            let textHeight = CATextLayer.lineHeight(Self.font)
            caption.frame = CGRect(x: StageGeometry.trunkInset + 12, y: y + 5, width: 140, height: textHeight)
            for (index, id) in order.reversed().enumerated() { dots[id]?.position = up(geometry.commitPosition(index: index)) }
        }
    }

    /// Shows the commit dots for `merged` (oldest first). A dot that is new is
    /// returned so the stage can drop it from its node.
    @discardableResult
    func show(merged ids: [String]) -> [CALayer] {
        let recent = Array(ids.suffix(StageGeometry.commitsShown))
        var added: [CALayer] = []
        CALayer.instantly {
            for id in order where !recent.contains(id) {
                dots[id]?.removeFromSuperlayer()
                dots[id] = nil
            }
            for id in recent where dots[id] == nil {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
                dot.cornerRadius = Self.dotSize / 2
                dot.contentsScale = contentsScale
                dots[id] = dot
                addSublayer(dot)
                added.append(dot)
            }
            order = recent
            for (index, id) in recent.reversed().enumerated() {
                guard let dot = dots[id] else { continue }
                dot.position = up(geometry.commitPosition(index: index))
                // The newest is the brightest; the older ones settle back.
                dot.backgroundColor = (index == 0 ? CockpitStyle.success : CockpitStyle.success.withAlphaComponent(max(0.7 - CGFloat(index) * 0.06, 0.25))).cgColor
            }
        }
        return added
    }

    func dot(for id: String) -> CALayer? { dots[id] }

    private func up(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: geometry.size.height - point.y) }
}

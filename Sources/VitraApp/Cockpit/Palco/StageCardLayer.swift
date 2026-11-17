import AppKit
import QuartzCore
import VitraOrchestrator
import VitraPanel

/// The small card that follows the pointer onto a node: model, effort, kind,
/// when it started, and what it cost where that is known.
final class StageCardLayer: CALayer {
    private static let width: CGFloat = 214
    private static let padding: CGFloat = 10
    private let text = CATextLayer()
    private var shownKey: String?

    override init() {
        super.init()
        backgroundColor = CockpitStyle.raised.cgColor
        borderColor = CockpitStyle.raisedLine.cgColor
        borderWidth = 1
        cornerRadius = CockpitStyle.Radius.card
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.4
        shadowRadius = 10
        shadowOffset = CGSize(width: 0, height: -3)
        text.isWrapped = true
        text.truncationMode = .end
        text.actions = ["contents": NSNull(), "string": NSNull(), "bounds": NSNull(), "position": NSNull()]
        addSublayer(text)
        isHidden = true
        zPosition = 100
        actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "contents": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the card says about `node`.
    static func content(for node: StageNode, now: Date) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ color: NSColor, gap: Bool = true) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.paragraphSpacing = gap ? 3 : 0
            result.append(NSAttributedString(string: string + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        let model = [node.model.split(separator: "/").last.map(String.init) ?? node.model, node.effort].compactMap { $0 }.joined(separator: " · ")
        add(model, CockpitStyle.ui(12, .semibold), CockpitStyle.text)
        add(node.label, CockpitStyle.ui(11), CockpitStyle.muted)
        let kind = [node.kind.map(WorkerBoard.kindName), node.canEdit ? "edita" : "só leitura"].compactMap { $0 }.joined(separator: " · ")
        add(kind, CockpitStyle.meta, CockpitStyle.code)
        add("iniciado " + WorkerBoard.startedText(node.started, now: now) + " · " + node.stateText, CockpitStyle.meta, StagePalette.stateText(node).blended(withFraction: 0.4, of: CockpitStyle.code) ?? CockpitStyle.code)
        let spent = [node.costUSD.map(WorkerBoard.money), node.tokens.map(WorkerBoard.tokens)].compactMap { $0 }.joined(separator: " · ")
        if !spent.isEmpty { add(spent, CockpitStyle.meta, CockpitStyle.muted, gap: false) }
        result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        return result
    }

    /// Shows the card for `node` beside `anchor` (y-up, in the stage's layer),
    /// kept inside `bounds`.
    func show(_ node: StageNode, now: Date, anchor: CGPoint, in bounds: CGRect) {
        let content = Self.content(for: node, now: now)
        let key = node.id + content.string
        if key != shownKey {
            shownKey = key
            let inner = Self.width - 2 * Self.padding
            let height = ceil(content.boundingRect(with: CGSize(width: inner, height: 200), options: [.usesLineFragmentOrigin]).height)
            CALayer.instantly {
                text.string = content
                self.bounds = CGRect(x: 0, y: 0, width: Self.width, height: height + 2 * Self.padding)
                text.frame = CGRect(x: Self.padding, y: Self.padding, width: inner, height: height)
            }
        }
        let size = self.bounds.size
        // Above the node when there is room, else below it.
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y + 30)
        if origin.y + size.height > bounds.maxY - 4 { origin.y = anchor.y - 30 - size.height }
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - size.width - 6)
        origin.y = min(max(origin.y, bounds.minY + 6), bounds.maxY - size.height - 6)
        CALayer.instantly {
            position = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            isHidden = false
        }
    }

    func hide() {
        shownKey = nil
        CALayer.instantly { isHidden = true }
    }
}

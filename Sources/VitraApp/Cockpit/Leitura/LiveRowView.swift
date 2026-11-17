import AppKit
import QuartzCore

/// The last row while the maestro works: "trabalhando · Rodar os testes ·
/// 1:12", with a small breathing dot. The dot is a Core Animation loop —
/// nothing redraws for it — and stands still under Reduce Motion or when the
/// row is off screen. The clock is ticked by the list, once a second, only
/// while this row is shown.
final class LiveRowView: LeituraRowView {
    static let height: CGFloat = 40
    private let dot = CALayer()
    private let label = NSTextField.label(font: ReadingStyle.small, color: ReadingStyle.quiet)
    private var since = Date()
    private var current: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.backgroundColor = CockpitStyle.accent.cgColor
        dot.cornerRadius = 3.5
        layer?.addSublayer(dot)
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func configure(_ row: LeituraRow, context: LeituraContext) {
        super.configure(row, context: context)
        guard case let .live(state) = row else { return }
        since = state.since
        current = state.current
        tick()
    }

    /// The clock moved on a second.
    func tick() {
        let text = NSMutableAttributedString(string: "trabalhando", attributes: [.font: ReadingStyle.smallMedium, .foregroundColor: CockpitStyle.accent])
        if let current {
            text.append(NSAttributedString(string: "  ·  " + current, attributes: [.font: ReadingStyle.small, .foregroundColor: ReadingStyle.quiet]))
        }
        text.append(NSAttributedString(string: "  ·  " + ReadingDuration.clock((context?.now() ?? Date()).timeIntervalSince(since)), attributes: [
            .font: CockpitStyle.meta.withMonospacedDigits, .foregroundColor: ReadingStyle.faint,
        ]))
        label.attributedStringValue = text
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate(window != nil)
    }

    private func animate(_ on: Bool) {
        dot.removeAllAnimations()
        guard on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
    }

    override func layout() {
        super.layout()
        let column = ReadingStyle.column(in: bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: column.x + 4, y: bounds.height / 2 - 3.5, width: 7, height: 7)
        CATransaction.commit()
        label.frame = NSRect(x: column.x + 22, y: bounds.height / 2 - 8, width: column.width - 22, height: 16)
    }
}

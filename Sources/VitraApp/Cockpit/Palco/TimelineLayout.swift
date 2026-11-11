import CoreGraphics
import Foundation

/// The timeline's arithmetic: which lane each run gets, how time maps to x,
/// and where the minute gridlines fall. Pure, so the view only places layers.
struct TimelineLayout: Equatable {
    /// The most the window looks back.
    static let window: TimeInterval = 30 * 60
    /// The least it covers, so a worker that has just started is not a sliver.
    static let minimumSpan: TimeInterval = 4 * 60
    /// Room after "now", as a share of the span, for bars to grow into.
    static let lookahead: Double = 0.07
    static let lineSteps: [TimeInterval] = [60, 120, 300, 600, 900, 1800]
    static let minimumLineGap: CGFloat = 46

    let start: Date
    let end: Date
    /// The width the span is spread over.
    let width: CGFloat

    /// The window for `nodes` at `now`: the last 30 minutes, narrowed to the
    /// oldest run shown when that started later.
    init(nodes: [StageNode], now: Date, width: CGFloat) {
        let oldest = nodes.map(\.started).min() ?? now
        let back = min(max(now.timeIntervalSince(oldest) * 1.04, Self.minimumSpan), Self.window)
        start = now.addingTimeInterval(-back)
        end = now.addingTimeInterval(back * Self.lookahead)
        self.width = max(width, 1)
    }

    var span: TimeInterval { end.timeIntervalSince(start) }

    /// Time → x, not clamped.
    func x(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / span) * width
    }

    /// Time → x, held inside the window: a run that began before it starts at its edge.
    func clampedX(_ date: Date) -> CGFloat {
        min(max(x(date), 0), width)
    }

    /// The bar for a run: from its start, or the window's edge, to its end or now.
    func bar(of node: StageNode, now: Date) -> (minX: CGFloat, maxX: CGFloat) {
        let from = clampedX(node.started)
        let to = clampedX(node.ended ?? now)
        return (from, max(to, min(from + 3, width)))
    }

    // MARK: Lanes

    struct Lane: Equatable {
        let id: String
        let isAudit: Bool
        let minY: CGFloat
        let height: CGFloat
    }

    /// Run ids in lane order: by start, each audit directly under its delivery.
    static func order(_ nodes: [StageNode]) -> [StageNode] {
        let byStart = nodes.sorted { ($0.started, $0.id) < ($1.started, $1.id) }
        let attached = Set(byStart.filter { $0.isAudit && $0.auditOf != nil }.map(\.id))
        var result: [StageNode] = []
        for node in byStart where !attached.contains(node.id) {
            result.append(node)
            result += byStart.filter { attached.contains($0.id) && $0.auditOf == node.id }
        }
        return result
    }

    /// The lanes, top to bottom, fitted into `height`: a delivery's lane is
    /// `row` points tall and an audit's a little over half that.
    static func lanes(_ nodes: [StageNode], height: CGFloat, preferredRow: CGFloat = 18, gap: CGFloat = 5) -> [Lane] {
        let ordered = order(nodes)
        guard !ordered.isEmpty else { return [] }
        let units = ordered.reduce(CGFloat(0)) { $0 + ($1.isAudit ? auditShare : 1) }
        let gaps = gap * CGFloat(ordered.count - 1)
        let row = max(min(preferredRow, (height - gaps) / units), 4)
        var y: CGFloat = 0
        return ordered.map { node in
            let h = node.isAudit ? row * auditShare : row
            defer { y += h + gap }
            return Lane(id: node.id, isAudit: node.isAudit, minY: y, height: h)
        }
    }

    static let auditShare: CGFloat = 0.55

    // MARK: Gridlines

    struct Line: Equatable {
        let date: Date
        let x: CGFloat
        let label: String
    }

    /// A line on every whole step (a minute, five, fifteen…) inside the window,
    /// the step being the smallest that keeps them `minimumLineGap` apart.
    func lines(timeZone: TimeZone = .current) -> [Line] {
        let step = Self.lineSteps.first { CGFloat($0 / span) * width >= Self.minimumLineGap } ?? Self.lineSteps[Self.lineSteps.count - 1]
        // Whole steps of the local clock, not of the epoch: a zone a half hour
        // off UTC would otherwise put its lines at :15 and :45.
        let offset = TimeInterval(timeZone.secondsFromGMT(for: start))
        var t = ((start.timeIntervalSince1970 + offset) / step).rounded(.up) * step - offset
        var lines: [Line] = []
        while t < end.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: t)
            lines.append(Line(date: date, x: x(date), label: Self.clock(date, timeZone: timeZone)))
            t += step
        }
        return lines
    }

    /// "19:40", without a formatter.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let seconds = Int((date.timeIntervalSince1970 + TimeInterval(timeZone.secondsFromGMT(for: date))).rounded(.down))
        let minuteOfDay = ((seconds % 86_400) + 86_400) % 86_400 / 60
        return String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }
}

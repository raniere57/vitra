import CoreGraphics
import Foundation

/// Which angle each worker has, kept for as long as the worker is on the stage.
///
/// Twelve slots, 30° apart. The even ones are the outer orbit and fill first,
/// each new worker taking the free slot farthest from those taken, so a few
/// workers are spread out rather than bunched; the odd ones are an inner orbit,
/// used once the outer is full. A worker never changes slot, so nothing moves
/// when another arrives or leaves.
struct SlotBook: Equatable {
    static let count = 12

    private(set) var slots: [String: Int] = [:]

    /// Frees the slots of workers no longer shown and gives the new ones theirs.
    /// `ids` come in start order, so the oldest of a batch gets the first pick.
    mutating func update(ids: [String]) {
        let live = Set(ids)
        slots = slots.filter { live.contains($0.key) }
        for id in ids where slots[id] == nil {
            guard let slot = nextFreeSlot() else { return }
            slots[id] = slot
        }
    }

    private func nextFreeSlot() -> Int? {
        let taken = Set(slots.values)
        let free = (0..<Self.count).filter { !taken.contains($0) }
        let outer = free.filter { $0 % 2 == 0 }
        let candidates = outer.isEmpty ? free : outer
        // The farthest from any taken slot; the lowest number wins a tie.
        return candidates.max { a, b in
            let (da, db) = (Self.gap(a, taken), Self.gap(b, taken))
            return da != db ? da < db : a > b
        }
    }

    private static func gap(_ slot: Int, _ taken: Set<Int>) -> Int {
        taken.map { other in
            let d = abs(slot - other)
            return min(d, count - d)
        }.min() ?? count
    }
}

/// Where things sit on a stage of a given size. Coordinates run from the top
/// left, like the layers that use them.
struct StageGeometry: Equatable {
    static let coreRadius: CGFloat = 34
    static let nodeRadius: CGFloat = 16
    static let auditRadius: CGFloat = 9
    /// What the trunk and its caption take from the bottom.
    static let trunkHeight: CGFloat = 46
    /// The inner orbit's size against the outer's.
    static let innerScale: CGFloat = 0.66
    /// Slot 0 sits up and to the left, clear of the core's own title.
    static let firstAngle: CGFloat = -2 * .pi / 3

    let size: CGSize

    /// From the sides to an outer node's centre: half its label's width.
    private static let marginX: CGFloat = 46
    /// From the top, and from the trunk, to an outer node's centre: the node
    /// and its three lines of text, which sit above it at the top and below it
    /// at the bottom.
    private static let marginY: CGFloat = 58

    var center: CGPoint { CGPoint(x: size.width / 2, y: Self.marginY + radii.height) }

    /// The outer orbit's half-width and half-height.
    var radii: CGSize {
        CGSize(
            width: max(size.width / 2 - Self.marginX, Self.coreRadius * 2),
            height: max((size.height - Self.trunkHeight - 2 * Self.marginY) / 2, Self.coreRadius * 1.6)
        )
    }

    func angle(ofSlot slot: Int) -> CGFloat {
        Self.firstAngle + CGFloat(slot) * 2 * .pi / CGFloat(SlotBook.count)
    }

    func position(ofSlot slot: Int) -> CGPoint {
        let scale = slot % 2 == 0 ? 1 : Self.innerScale
        let theta = angle(ofSlot: slot)
        return CGPoint(x: center.x + radii.width * scale * cos(theta), y: center.y + radii.height * scale * sin(theta))
    }

    /// Where an audit hangs: level with its delivery's disc, on the side away
    /// from the core's axis. Level, because the delivery's words sit above or
    /// below the disc and an audit there would land on them; and turned to the
    /// other side when there is no room on the first.
    func auditPosition(besideDelivery point: CGPoint) -> CGPoint {
        let reach = Self.nodeRadius + Self.auditRadius + 8
        let away: CGFloat = point.x >= center.x ? 1 : -1
        let x = point.x + away * reach
        let inside = x >= Self.auditRadius + 4 && x <= size.width - Self.auditRadius - 4
        return CGPoint(x: inside ? x : point.x - away * reach, y: point.y)
    }

    // MARK: Where a node's words go

    /// Which side of its disc a node carries its label, state and dots on.
    enum TextSide: CaseIterable, Equatable {
        case above, below, left, right
    }

    /// The block of a node's words: label, state line and rating dots.
    static let textSize = CGSize(width: 84, height: 34)
    /// From the disc's edge to its words.
    static let textGap: CGFloat = 3
    /// The least room between a node's words and any other node or words.
    static let textClearance: CGFloat = 6
    /// How far the core's dotted ring reaches past its disc.
    static let coreRingReach: CGFloat = 12

    /// Where the words of a node at `point` sit on `side`, top-left coordinates.
    static func textRect(at point: CGPoint, side: TextSide, radius: CGFloat = nodeRadius) -> CGRect {
        let size = textSize
        let reach = radius + textGap
        switch side {
        case .above: return CGRect(x: point.x - size.width / 2, y: point.y - reach - size.height, width: size.width, height: size.height)
        case .below: return CGRect(x: point.x - size.width / 2, y: point.y + reach, width: size.width, height: size.height)
        case .left: return CGRect(x: point.x - reach - size.width, y: point.y - size.height / 2, width: size.width, height: size.height)
        case .right: return CGRect(x: point.x + reach, y: point.y - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// The side each node's words go on, so that they keep `textClearance`
    /// from every other disc and every other node's words, and stay on the
    /// stage. A node prefers the side away from the core vertically (above in
    /// the upper half), then the opposite, then outward, then inward; where
    /// none is clear, the side with the most room. `discs` holds every disc on
    /// the stage, audits included; `labelled` the ids that carry words, in the
    /// order they choose.
    func textSides(labelled: [String], discs: [(id: String, point: CGPoint, radius: CGFloat)]) -> [String: TextSide] {
        let stage = CGRect(origin: .zero, size: CGSize(width: size.width, height: trunkY - 8))
        var chosen: [String: CGRect] = [:]
        var sides: [String: TextSide] = [:]
        // The core and its dotted ring are in the way too.
        let discs = discs + [(id: "", point: center, radius: Self.coreRadius + Self.coreRingReach)]
        for id in labelled {
            guard let me = discs.first(where: { $0.id == id }) else { continue }
            let vertical: [TextSide] = me.point.y < center.y - 8 ? [.above, .below] : [.below, .above]
            let horizontal: [TextSide] = me.point.x < center.x ? [.left, .right] : [.right, .left]
            let room = { (side: TextSide) -> CGFloat in
                let rect = Self.textRect(at: me.point, side: side, radius: me.radius)
                var least = Self.inset(rect, within: stage)
                for disc in discs where disc.id != id {
                    least = min(least, Self.distance(from: rect, to: disc.point) - disc.radius)
                }
                for (other, placed) in chosen where other != id {
                    least = min(least, Self.gap(rect, placed))
                }
                return least
            }
            let order = vertical + horizontal
            let side = order.first { room($0) >= Self.textClearance }
                ?? order.max { room($0) < room($1) }
                ?? vertical[0]
            sides[id] = side
            chosen[id] = Self.textRect(at: me.point, side: side, radius: me.radius)
        }
        return sides
    }

    /// How far `rect` sits inside `bounds`: negative when it pokes out.
    private static func inset(_ rect: CGRect, within bounds: CGRect) -> CGFloat {
        min(rect.minX - bounds.minX, rect.minY - bounds.minY, bounds.maxX - rect.maxX, bounds.maxY - rect.maxY) + textClearance
    }

    static func distance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// The empty space between two rectangles; negative when they overlap.
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(b.minX - a.maxX, a.minX - b.maxX)
        let dy = max(b.minY - a.maxY, a.minY - b.maxY)
        return dx < 0 && dy < 0 ? max(dx, dy) : hypot(max(dx, 0), max(dy, 0))
    }

    // MARK: The trunk

    var trunkY: CGFloat { size.height - 18 }
    static let trunkInset: CGFloat = 24
    static let commitSpacing: CGFloat = 16
    static let commitsShown = 10

    /// Where the `index`th most recent commit dot sits: the newest at the right.
    func commitPosition(index: Int) -> CGPoint {
        CGPoint(x: size.width - Self.trunkInset - 6 - CGFloat(index) * Self.commitSpacing, y: trunkY)
    }

    // MARK: Hovering

    /// The id of the node under `point`, if any; the smallest wins where audits overlap.
    static func hit(_ point: CGPoint, in centres: [(id: String, point: CGPoint, radius: CGFloat)]) -> String? {
        centres
            .filter { hypot($0.point.x - point.x, $0.point.y - point.y) <= $0.radius + 6 }
            .min { $0.radius < $1.radius }?.id
    }
}

/// The curved line from one point to another, and where along it a particle is.
struct LinkCurve: Equatable {
    let from: CGPoint
    let to: CGPoint
    /// The side it bows to, +1 or -1.
    let bend: CGFloat

    var control: CGPoint {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        return CGPoint(x: mid.x - dy * 0.16 * bend, y: mid.y + dx * 0.16 * bend)
    }

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let c = control
        return CGPoint(
            x: u * u * from.x + 2 * u * t * c.x + t * t * to.x,
            y: u * u * from.y + 2 * u * t * c.y + t * t * to.y
        )
    }

    var path: CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        return path
    }

    /// The same curve walked the other way, for the pulse that comes home.
    var reversed: LinkCurve { LinkCurve(from: to, to: from, bend: -bend) }
}

/// Whether the Palco's repeating animations may run.
enum StageLiveness {
    /// Particles, breathing, the turning ring and the bar sheen run only while
    /// the tab is on screen, the window can be seen, a worker is running and the
    /// user has not asked for less motion. Anything else leaves static layers.
    static func animates(isOnScreen: Bool, hasRunning: Bool, reduceMotion: Bool) -> Bool {
        isOnScreen && hasRunning && !reduceMotion
    }
}

/// Which finished workers' branches have been merged, learned by seeing a
/// branch that was there go away.
struct MergeTracker: Equatable {
    private var seen: Set<String> = []
    private(set) var merged: [String] = []

    /// Notes which of `branches` (run id → branch) exist now, and returns the
    /// ids that were seen to exist before and no longer do. A branch never seen
    /// is not a merge: a worker listed after its branch was long gone is not news.
    ///
    /// `accepted` are finished editing runs the maestro rated 4 or more: one of
    /// those whose branch is gone counts as merged even if its branch was never
    /// seen — it was merged before the tab opened. Each id drops once.
    mutating func update(branches: [String: String], existing: Set<String>, accepted: Set<String> = []) -> [String] {
        var news: [String] = []
        for (id, branch) in branches.sorted(by: { $0.key < $1.key }) {
            if existing.contains(branch) {
                seen.insert(id)
            } else if seen.remove(id) != nil || accepted.contains(id), !merged.contains(id) {
                merged.append(id)
                news.append(id)
            }
        }
        // An accepted run with no branch on record has nothing left to merge.
        for id in accepted.sorted() where branches[id] == nil && !merged.contains(id) {
            merged.append(id)
            news.append(id)
        }
        return news
    }

    /// The last `limit` merged ids, oldest first.
    func recent(_ limit: Int = StageGeometry.commitsShown) -> [String] { Array(merged.suffix(limit)) }
}

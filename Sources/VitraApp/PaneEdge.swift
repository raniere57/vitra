import Foundation

/// Which side of a pane a drop lands on.
///
/// A pane dropped in the middle of another has no obvious meaning, so the whole
/// pane is divided into four wedges from its centre: the side the pointer is in
/// is the side the pane goes to, and that is the whole gesture.
public enum PaneEdge: Sendable {
    case leading, trailing, top, bottom

    /// True when the two panes end up side by side rather than stacked.
    public var isVertical: Bool { self == .leading || self == .trailing }

    /// True when the dropped pane comes first in the split.
    public var isBefore: Bool { self == .leading || self == .top }

    /// The wedge `point` falls in, measured from the centre of `rect`.
    ///
    /// Compared as fractions of width and height, so a wide pane's left and
    /// right wedges stay left and right instead of collapsing into slivers.
    public static func nearest(to point: CGPoint, in rect: CGRect) -> PaneEdge {
        guard rect.width > 0, rect.height > 0 else { return .trailing }
        let x = (point.x - rect.midX) / rect.width
        let y = (point.y - rect.midY) / rect.height
        if abs(x) >= abs(y) { return x < 0 ? .leading : .trailing }
        // Views here are top-left origin, so a larger y is further down.
        return y < 0 ? .top : .bottom
    }

    /// The half of `rect` a drop on this edge would take.
    public func half(of rect: CGRect) -> CGRect {
        switch self {
        case .leading: return CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height)
        case .trailing: return CGRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height)
        case .top: return CGRect(x: 0, y: 0, width: rect.width, height: rect.height / 2)
        case .bottom: return CGRect(x: 0, y: rect.height / 2, width: rect.width, height: rect.height / 2)
        }
    }
}

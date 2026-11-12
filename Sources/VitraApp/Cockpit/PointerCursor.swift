import AppKit

/// Every button shows the pointing hand, as anything clickable should: AppKit
/// keeps the arrow by default. One override here instead of a subclass at
/// each of the app's buttons; AppKit's own private buttons (the window's
/// traffic lights) are left as they are.
extension NSButton {
    override open func resetCursorRects() {
        guard isEnabled, !className.hasPrefix("_") else { return super.resetCursorRects() }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

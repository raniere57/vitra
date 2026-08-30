import AppKit

/// A view that renders one previewed file.
///
/// `prepareForRemoval` exists for the web view, whose content process outlives
/// the view unless it is torn down deliberately.
protocol PreviewContentView: NSView {
    func prepareForRemoval()
}

extension PreviewContentView {
    func prepareForRemoval() {}
}

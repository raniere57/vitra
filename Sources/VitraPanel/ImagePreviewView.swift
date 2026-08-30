import AppKit
import ImageIO
import VitraCore

/// An image, scaled to fit, with scroll-to-zoom.
///
/// The file is decoded through `CGImageSource` at no more than the screen's
/// pixel size. A 6K screenshot is ~100 MB decoded at full resolution and the
/// panel is a few hundred points wide, so the full-resolution decode is deferred
/// until the view is actually magnified.
final class ImagePreviewView: NSScrollView, PreviewContentView {
    private let imageView = NSImageView()
    private let url: URL
    private var isFullResolutionLoaded = false

    init?(target: PreviewTarget) {
        url = target.url
        super.init(frame: .zero)

        guard let thumbnail = Self.decode(url, maxPixelSize: Self.screenPixelSize()) else { return nil }

        imageView.image = NSImage(cgImage: thumbnail, size: .zero)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]

        documentView = imageView
        hasVerticalScroller = false
        hasHorizontalScroller = false
        drawsBackground = true
        backgroundColor = PanelStyle.surface
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 8

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(magnificationEnded),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        // The document view fills the clip view so the image stays centred; the
        // scroll view only has something to scroll once it is magnified.
        if magnification == 1 { imageView.frame = bounds }
    }

    /// Swaps in the full-resolution decode once zooming makes it worth its cost.
    @objc private func magnificationEnded() {
        guard !isFullResolutionLoaded, magnification > 1.5 else { return }
        isFullResolutionLoaded = true
        guard let full = Self.decode(url, maxPixelSize: nil) else { return }
        imageView.image = NSImage(cgImage: full, size: .zero)
    }

    /// The largest sensible decode: the biggest screen, in backing pixels.
    private static func screenPixelSize() -> Int {
        let screens = NSScreen.screens
        let longest = screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max()
        return Int(longest ?? 3840)
    }

    private static func decode(_ url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

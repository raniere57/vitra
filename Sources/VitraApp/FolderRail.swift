import AppKit
import VitraCore

/// The strip of favourite folders down the left edge of a window.
///
/// The folders are the app's real navigation, so they live on an edge rather
/// than behind a menu: one click per folder, and the window says which one it
/// belongs to without anything being opened first.
@MainActor
final class FolderRail: NSView {
    static let width: CGFloat = 52

    /// Opens a folder, and adds one.
    var onOpen: ((Bookmark) -> Void)?
    var onMenu: ((NSButton) -> Void)?

    private let stack = NSStackView()
    private var bookmarks: [Bookmark] = []
    private var current: Bookmark.ID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Centred on the rail rather than stretched across it: a stack pinned to
        // both edges left its buttons on the left of a 52pt column, which is the
        // gutter that showed on the right of every icon.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The rail is chrome, not terminal: it takes the theme's background a
    /// shade off so the panes read as the content and it reads as the frame.
    func apply(_ config: Config) {
        let background = NSColor(hex: config.theme.background.hex) ?? .black
        layer?.backgroundColor = background.blended(withFraction: 0.04, of: .white)?.cgColor
        needsDisplay = true
    }

    func update(bookmarks: [Bookmark], current: Bookmark.ID?) {
        self.bookmarks = bookmarks
        self.current = current

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, bookmark) in bookmarks.enumerated() {
            stack.addArrangedSubview(button(for: bookmark, index: index))
        }

        if !bookmarks.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(separator)
            NSLayoutConstraint.activate([
                separator.widthAnchor.constraint(equalToConstant: 22),
                separator.heightAnchor.constraint(equalToConstant: 1),
            ])
        }

        stack.addArrangedSubview(menuButton())
    }

    private func button(for bookmark: Bookmark, index: Int) -> NSButton {
        let button = RailButton()
        button.image = NSImage(systemSymbolName: bookmark.symbolName, accessibilityDescription: bookmark.name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        // NSButton's stock title is the word "Button": an icon-only rail button
        // has to be told it has no title, or that word is what the rail shows.
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.toolTip = "\(bookmark.name) — \(bookmark.displayPath)"
        button.target = self
        button.action = #selector(openTapped(_:))
        button.tag = index
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 34),
        ])

        // The window's own folder is lit in its colour; the rest sit back so the
        // lit one is findable without reading a single label.
        let isCurrent = bookmark.id == current
        let accent = bookmark.colorHex.flatMap { NSColor(hex: $0) } ?? .controlAccentColor
        button.layer?.backgroundColor = isCurrent
            ? accent.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        button.layer?.borderWidth = isCurrent ? 1 : 0
        button.layer?.borderColor = accent.withAlphaComponent(0.5).cgColor
        button.contentTintColor = isCurrent ? accent : .secondaryLabelColor
        button.alphaValue = isCurrent ? 1 : 0.8
        return button
    }

    private func menuButton() -> NSButton {
        let button = RailButton()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Folders")
        // NSButton's stock title is the word "Button"; an icon-only rail button
        // has to say so, or that word is what the rail shows.
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = "Folders — open, favourite, manage (⌘P)"
        button.target = self
        button.action = #selector(menuTapped(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alphaValue = 0.6
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        return button
    }

    @objc private func openTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < bookmarks.count else { return }
        onOpen?(bookmarks[sender.tag])
    }

    @objc private func menuTapped(_ sender: NSButton) {
        onMenu?(sender)
    }
}

/// A rail button that draws nothing of its own.
///
/// The stock bezel paints a light rounded rectangle that fights the terminal
/// behind it; the tint and the ring come from the layer instead.
private final class RailButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        attributedTitle.draw(in: titleRect())
        if let image {
            let size = NSSize(width: 13, height: 13)
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            image.isTemplate = true
            NSColor.secondaryLabelColor.set()
            image.draw(in: NSRect(origin: origin, size: size))
        }
    }

    private func titleRect() -> NSRect {
        let size = attributedTitle.size()
        return NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

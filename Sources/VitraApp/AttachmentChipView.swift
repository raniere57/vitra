import AppKit
import QuickLookThumbnailing
import VitraCore

/// A row of chips naming the files just attached to the prompt.
///
/// Purely informational: it does not take clicks, does not cover the prompt, and
/// fades out on its own. The path has already been typed into the prompt by the
/// time a chip appears — the chip only confirms what went in.
final class AttachmentChipView: NSView {
    private let stack = NSStackView()
    private var dismissWorkItem: DispatchWorkItem?

    /// How long chips stay before fading out.
    private let visibleDuration: TimeInterval = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        // Ignore hit testing entirely; the terminal underneath keeps the mouse.
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ attachments: [Attachment]) {
        guard !attachments.isEmpty else { return }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments.prefix(4) {
            stack.addArrangedSubview(makeChip(for: attachment))
        }
        if attachments.count > 4 {
            stack.addArrangedSubview(makeLabel("+\(attachments.count - 4) more"))
        }

        dismissWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }

        let dismiss = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: dismiss)
    }

    func fadeOut() {
        dismissWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        }
    }

    // MARK: - Chips

    private func makeChip(for attachment: Attachment) -> NSView {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        chip.layer?.cornerRadius = 6
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor

        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.image = NSWorkspace.shared.icon(forFile: attachment.path)
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        loadThumbnail(for: attachment, into: thumbnail)

        let label = makeLabel(attachment.displayName)

        let row = NSStackView(views: [thumbnail, label])
        row.orientation = .horizontal
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(row)

        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: 18),
            thumbnail.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            row.topAnchor.constraint(equalTo: chip.topAnchor),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
        ])
        return chip
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.85)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Replaces the generic type icon with a real preview once QuickLook has one.
    private func loadThumbnail(for attachment: Attachment, into imageView: NSImageView) {
        let request = QLThumbnailGenerator.Request(
            fileAt: attachment.url,
            size: CGSize(width: 36, height: 36),
            scale: window?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            // Convert on the callback's own thread: NSImage is Sendable, the
            // QuickLook representation is not.
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { imageView.image = image }
        }
    }
}

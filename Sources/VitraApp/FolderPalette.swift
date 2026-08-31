import AppKit
import VitraCore

/// The quick switcher: type a few letters, open a terminal in that folder.
///
/// A palette rather than a permanent sidebar. A sidebar costs width in every
/// window forever to answer a question asked a few times a day, and this app's
/// width belongs to the terminal.
@MainActor
final class FolderPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// Called with the chosen folder. Nil means the user asked for a folder that
    /// is not a favourite yet, and the caller decides what that means.
    private var onChoose: ((Bookmark) -> Void)?

    private var panel: NSPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [Bookmark] = []
    private var shown: [Bookmark] = []

    func show(bookmarks: [Bookmark], onChoose: @escaping (Bookmark) -> Void) {
        self.onChoose = onChoose
        all = bookmarks
        shown = bookmarks

        let panel = self.panel ?? makePanel()
        self.panel = panel

        field.stringValue = ""
        table.reloadData()
        select(0)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        let content = NSVisualEffectView(frame: panel.contentLayoutRect)
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.autoresizingMask = [.width, .height]

        field.placeholderString = "Go to folder"
        field.font = .systemFont(ofSize: 20, weight: .light)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.frame = NSRect(x: 18, y: content.bounds.height - 52, width: content.bounds.width - 36, height: 30)
        field.autoresizingMask = [.width, .minYMargin]

        let separator = NSBox(frame: NSRect(x: 0, y: content.bounds.height - 62, width: content.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        column.width = content.bounds.width
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)

        let scroll = NSScrollView(frame: NSRect(
            x: 0, y: 0,
            width: content.bounds.width,
            height: content.bounds.height - 62
        ))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        // Without this the table keeps the width it was created with and every
        // row is laid out for a column narrower than the window.
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        content.addSubview(scroll)
        content.addSubview(separator)
        content.addSubview(field)
        panel.contentView = content
        return panel
    }

    // MARK: - Filtering

    func controlTextDidChange(_ notification: Notification) {
        let query = field.stringValue
        shown = all.filter { $0.matches(query) }
        table.reloadData()
        select(0)
    }

    /// Arrow keys and Return, while the text field keeps focus.
    ///
    /// Without this the table would need focus to be navigable, and a palette
    /// where the user has to tab out of the search box to pick a result is a
    /// palette nobody uses twice.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(min(table.selectedRow + 1, shown.count - 1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            select(max(table.selectedRow - 1, 0))
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func select(_ row: Int) {
        guard row >= 0, row < shown.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let bookmark = shown[row]
        close()
        onChoose?(bookmark)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bookmark = shown[row]
        let cell = NSView()

        // Auto Layout for the whole row: the table resizes these views after
        // this method returns, and anything positioned by hand ends up under
        // the name once it does.
        let mark = NSView()
        mark.wantsLayer = true
        mark.layer?.backgroundColor = (bookmark.colorHex.flatMap { NSColor(hex: $0) } ?? .clear).cgColor
        mark.layer?.cornerRadius = 1.5

        let emoji = NSTextField(labelWithString: bookmark.emoji)
        emoji.font = .systemFont(ofSize: 20)

        let name = NSTextField(labelWithString: bookmark.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)

        let detail = NSTextField(labelWithString: bookmark.exists ? bookmark.displayPath : bookmark.displayPath + "  (missing)")
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        // A folder that has been moved is still listed, dimmed: an entry that
        // vanishes on its own looks like the app lost it.
        if !bookmark.exists { name.textColor = .tertiaryLabelColor }

        let tags = NSTextField(labelWithString: bookmark.tags.joined(separator: " · "))
        tags.font = .systemFont(ofSize: 10)
        tags.textColor = .tertiaryLabelColor
        tags.alignment = .right

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        // An explicit spacer: a stack view distributes slack to nothing by
        // default, which leaves the tags trailing the name at a different
        // distance on every line instead of lining up on the right.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [mark, emoji, text, spacer, tags])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false

        // The path gives up its width first: a long path truncates, a name and
        // its tags never do.
        // The spacer is what gives way first, so the name and the path keep
        // their natural width and only a genuinely long path truncates.
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tags.setContentHuggingPriority(.required, for: .horizontal)
        tags.setContentCompressionResistancePriority(.required, for: .horizontal)

        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            row.topAnchor.constraint(equalTo: cell.topAnchor),
            row.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            mark.widthAnchor.constraint(equalToConstant: 3),
            mark.heightAnchor.constraint(equalToConstant: 28),
            emoji.widthAnchor.constraint(equalToConstant: 24),
        ])
        return cell
    }
}

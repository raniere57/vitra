import AppKit

/// A drag that starts in one piece of text and runs on into the next
/// messages. Each message is a text view of its own, and AppKit's selection
/// stops at the edge of the view it began in: while the button is held, the
/// list follows the pointer itself, scrolls when it leaves the list, and
/// selects whole the text views in between.
@MainActor
final class CrossSelection {
    private weak var list: LeituraList?
    private weak var origin: ReadingTextView?
    private var anchor = 0
    private var originRow = 0
    private var timer: Timer?
    /// Rows the selection spans, first to last, once it left its view.
    private(set) var span: ClosedRange<Int>?

    init(list: LeituraList) { self.list = list }

    func begin(in view: ReadingTextView, at event: NSEvent) {
        start(in: view, anchor: view.characterIndexForInsertion(at: view.convert(event.locationInWindow, from: nil)))
        timer?.invalidate()
        // Common modes: the text view's own drag loop runs the event-tracking one.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func start(in view: ReadingTextView, anchor: Int) {
        clear(except: view)
        origin = view
        self.anchor = anchor
        originRow = list?.table.row(for: view) ?? 0
    }

    func end() {
        timer?.invalidate()
        timer = nil
    }

    /// Text views on screen, top to bottom, with their rows.
    private func visibleViews() -> [(row: Int, view: ReadingTextView, top: CGFloat)] {
        guard let table = list?.table else { return [] }
        let rows = table.rows(in: table.visibleRect)
        var found: [(Int, ReadingTextView, CGFloat)] = []
        for row in rows.location ..< NSMaxRange(rows) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            for view in Self.textViews(in: cell) {
                found.append((row, view, table.convert(view.bounds, from: view).minY))
            }
        }
        return found.sorted { ($0.0, $0.2) < ($1.0, $1.2) }
    }

    private static func textViews(in view: NSView) -> [ReadingTextView] {
        view.subviews.flatMap { sub -> [ReadingTextView] in
            if let text = sub as? ReadingTextView { return [text] }
            return textViews(in: sub)
        }
    }

    private func follow() {
        guard let list, let window = list.window, NSEvent.pressedMouseButtons & 1 == 1 else { return end() }
        let pointer = window.mouseLocationOutsideOfEventStream
        autoscroll(list, pointer: pointer)
        extend(to: pointer)
    }

    /// The selection from the origin to the text under `pointer`, in window
    /// coordinates.
    func extend(to pointer: NSPoint) {
        guard let list, let origin else { return }
        let point = list.table.convert(pointer, from: nil)
        let views = visibleViews()
        guard !views.isEmpty else { return }
        // Scrolled away, the origin still has its place in the order.
        let originShown = list.table.row(for: origin) == originRow
        let originIndex = views.firstIndex { $0.view === origin }
            ?? (views[0].row > originRow ? -1 : views.count)
        // The text the pointer is over, or the last one above it.
        let targetIndex = views.lastIndex { $0.top <= point.y } ?? 0
        guard targetIndex != originIndex else {
            clear(except: origin)
            return
        }
        let target = views[targetIndex].view
        let index = target.characterIndexForInsertion(at: target.convert(pointer, from: nil))
        let down = targetIndex > originIndex
        let between = down ? (originIndex + 1) ..< targetIndex : (targetIndex + 1) ..< originIndex
        for (position, entry) in views.enumerated() where entry.view !== origin {
            let length = entry.view.string.utf16.count
            let range: NSRange
            if between.contains(position) {
                range = NSRange(location: 0, length: length)
            } else if position == targetIndex {
                range = down ? NSRange(location: 0, length: index) : NSRange(location: index, length: length - index)
            } else {
                range = NSRange(location: 0, length: 0)
            }
            entry.view.setSelectedRange(range)
        }
        if originShown {
            let length = origin.string.utf16.count
            let anchor = min(anchor, length)
            origin.setSelectedRange(down ? NSRange(location: anchor, length: length - anchor) : NSRange(location: 0, length: anchor))
        }
        let rows = (originRow, views[targetIndex].row)
        span = min(rows.0, rows.1) ... max(rows.0, rows.1)
    }

    /// Past the list's top or bottom edge, the list scrolls, faster further out.
    private func autoscroll(_ list: LeituraList, pointer: NSPoint) {
        let clip = list.scroll.contentView
        let point = clip.convert(pointer, from: nil)
        let bounds = clip.bounds
        let beyond = point.y < bounds.minY ? point.y - bounds.minY : point.y > bounds.maxY ? point.y - bounds.maxY : 0
        guard beyond != 0 else { return }
        let insets = list.scroll.contentInsets
        let lowest = max(list.table.bounds.height - bounds.height + insets.bottom, -insets.top)
        let step = max(min(beyond, 120), -120) / 2
        let y = min(max(bounds.minY + step, -insets.top), lowest)
        clip.scroll(to: NSPoint(x: 0, y: y))
        list.scroll.reflectScrolledClipView(clip)
    }

    private func clear(except keep: ReadingTextView?) {
        span = nil
        for entry in visibleViews() where entry.view !== keep {
            entry.view.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    /// What is selected across the rows: the parts on screen as selected,
    /// rows scrolled away whole.
    func selectedText() -> String? {
        guard let span, let list else { return nil }
        let views = visibleViews()
        let parts: [String] = span.compactMap { row in
            let shown = views.filter { $0.row == row }
            let text: String
            if shown.isEmpty, list.rows.indices.contains(row) {
                text = Self.text(of: list.rows[row])
            } else {
                text = shown.map { ($0.view.string as NSString).substring(with: $0.view.selectedRange()) }
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func text(of row: LeituraRow) -> String {
        switch row {
        case let .item(.answer(answer)): answer.markdown
        case let .item(.user(message)): message.text
        default: ""
        }
    }
}

import AppKit

extension UISnapshot {
    /// A delivery's diff with two comments: one saved under a removed line,
    /// and one under an added line that is open for editing.
    static func diffReview(_ context: Context) throws -> NSView? {
        let fixtures = context.fixtures
        let delivery = fixtures.reviewDelivery
        let book = ReviewCommentBook()
        let view = DiffReviewView(delivery: delivery, book: book, isSolo: false, loads: false) { _, _ in }
        context.window.contentView?.addFilling(view)
        context.window.contentView?.layoutSubtreeIfNeeded()

        let files = fixtures.reviewDiff()
        let lines = DiffRows.build(files).compactMap { row -> (DiffLineRef, Int)? in
            if case let .line(ref, ordinal) = row { (ref, ordinal) } else { nil }
        }
        func comment(on fragment: String, _ text: String) throws -> (DiffLineRef, ReviewComment) {
            guard let (ref, ordinal) = lines.first(where: { files[$0.0.file].hunks[$0.0.hunk].lines[$0.0.line].text.contains(fragment) }),
                  let anchor = ReviewAnchor(path: files[ref.file].path, line: files[ref.file].hunks[ref.hunk].lines[ref.line]),
                  let saved = book.add(text, at: anchor, order: ordinal, run: delivery.runID)
            else { throw SnapshotError.render("no fixture line with \(fragment)") }
            return (ref, saved)
        }
        _ = try comment(on: "rows = listing.entries", "Isto recriava todas as linhas a cada listagem — bom que saiu. Confirme que nada mais chama FileRow.")
        let (editedLine, edited) = try comment(on: "cell.show(entries[row]", "showsHiddenFiles e root não existem em FileCell.show")
        view.show(files)
        view.beginComment(on: editedLine, rewriting: edited.id)
        return nil
    }
}

import AppKit

/// The table's side of the review: which view and how tall for each row.
extension DiffReviewView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .line: DiffGeometry.lineHeight
        case .file: DiffFileCell.height
        case .hunk: DiffTextCell.hunkHeight
        case .bare, .truncated: DiffTextCell.noteHeight
        case let .comment(comment): CommentPlate.height(of: comment.text, width: plateWidth)
        case .editor: DiffEditorCell.height
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .file = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .line = rows[row] { true } else { false }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard rows.indices.contains(row), let ref = rows[row].lineRef else { return }
        selected = ref
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: DiffRowView.identifier, owner: nil) as? DiffRowView ?? DiffRowView()
        view.wash = switch rows[row] {
        case let .line(ref, _):
            switch line(ref).kind {
            case .added: CockpitStyle.addedWash
            case .removed: CockpitStyle.removedWash
            case .context: CockpitStyle.panel
            }
        case .file: CockpitStyle.ground
        default: CockpitStyle.panel
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .line(ref, _):
            let cell = reuse(DiffLineCell.identifier) { DiffLineCell() }
            cell.geometry = geometry
            cell.line = line(ref)
            cell.hasComment = rows.indices.contains(row + 1) && {
                if case .comment = rows[row + 1] { return true }
                if case .editor(_, _, .some) = rows[row + 1] { return true }
                return false
            }()
            return cell
        case let .file(index):
            let cell = reuse(DiffFileCell.identifier) { DiffFileCell() }
            cell.show(files[index])
            return cell
        case let .hunk(file, hunk):
            let cell = reuse(DiffTextCell.identifier) { DiffTextCell() }
            // The first hunk sits on its file's header, which has its own rule.
            cell.show(files[file].hunks[hunk].header, at: geometry.signX, ruled: hunk > 0)
            return cell
        case let .bare(file):
            let cell = reuse(DiffTextCell.identifier) { DiffTextCell() }
            let text = files[file].isBinary ? "Arquivo binário — sem linhas para comentar." : "Sem mudanças no conteúdo."
            cell.show(text, at: geometry.signX, ruled: false)
            return cell
        case let .truncated(shown, total):
            let cell = reuse(DiffTextCell.identifier) { DiffTextCell() }
            let text = "Diff grande demais, mostrando as primeiras \(shown.formatted()) de \(total.formatted()) linhas."
            cell.show(text, at: CockpitStyle.inset, ruled: false, color: CockpitStyle.accent)
            return cell
        case let .comment(comment):
            let cell = reuse(DiffNoteCell.identifier) { DiffNoteCell() }
            cell.show(comment, at: geometry.textX, width: plateWidth)
            let ref = lineAbove(row)
            cell.onEdit = { [weak self] in
                guard let self, let ref else { return }
                self.beginComment(on: ref, rewriting: comment.id)
            }
            cell.onRemove = { [weak self] in self?.remove(comment.id) }
            return cell
        case let .editor(_, _, comment):
            let cell = reuse(DiffEditorCell.identifier) { DiffEditorCell() }
            cell.show(text: comment?.text ?? "", at: geometry.textX, width: plateWidth)
            cell.onSave = { [weak self] text in self?.endComment(saving: text) }
            cell.onCancel = { [weak self] in self?.endComment(saving: nil) }
            return cell
        }
    }

    private func line(_ ref: DiffLineRef) -> DiffLine {
        files[ref.file].hunks[ref.hunk].lines[ref.line]
    }

    /// The line a comment row hangs from: the nearest line above it, past
    /// the other comments on the same line.
    private func lineAbove(_ row: Int) -> DiffLineRef? {
        rows[..<row].last { $0.lineRef != nil }?.lineRef
    }

    private func reuse<Cell: NSView>(_ identifier: NSUserInterfaceItemIdentifier, make: () -> Cell) -> Cell {
        table.makeView(withIdentifier: identifier, owner: nil) as? Cell ?? make()
    }
}

import Foundation
import VitraOrchestrator

/// A delivery to review, for the diff-review picture: one file changed in two
/// places, one added, one renamed, one deleted and one binary, as git prints
/// them, read by the same parser the app uses.
extension SnapshotFixtures {
    var reviewDelivery: Delivery {
        Delivery(
            runID: "c3d4e5f6", label: "Migrar a lista de arquivos para células reutilizáveis",
            worker: "claude-sonnet-5-5 (medium)", repository: path, branch: "vitra/c3d4e5f6", base: "4f2a9c1", worktree: nil
        )
    }

    /// The workers with the delivery above finished on its branch, for the
    /// row that offers "Ver mudanças".
    func deliveryRuns() -> [Run] {
        workerRuns().map { run in
            guard run.id == reviewDelivery.runID else { return run }
            var delivered = run
            delivered.repository = path
            delivered.branch = reviewDelivery.branch
            delivered.baseCommit = reviewDelivery.base
            return delivered
        }
    }

    func reviewDiff() -> [DiffFile] {
        UnifiedDiff.parse(Self.reviewDiffText)
    }

    private static let reviewDiffText = """
    diff --git a/Sources/VitraPanel/FileListView.swift b/Sources/VitraPanel/FileListView.swift
    index 3b1c2d0..9e4f7a2 100644
    --- a/Sources/VitraPanel/FileListView.swift
    +++ b/Sources/VitraPanel/FileListView.swift
    @@ -12,14 +12,14 @@ public final class FileListView: NSView {
         private let scroll = NSScrollView()
    -    private var rows: [FileRow] = []
    -    private let stack = NSStackView()
    +    private let table = NSTableView()
    +    private var entries: [DirectoryListing.Entry] = []
    +    private static let rowIdentifier = NSUserInterfaceItemIdentifier("file")

         public var onOpen: ((URL) -> Void)?

         public func show(_ listing: DirectoryListing) {
    -        rows.forEach { $0.removeFromSuperview() }
    -        rows = listing.entries.map(FileRow.init)
    -        rows.forEach(stack.addArrangedSubview)
    +        entries = listing.entries
    +        table.reloadData()
         }

         override public func layout() {
             super.layout()
    @@ -48,4 +48,16 @@ public final class FileListView: NSView {
             scroll.hasVerticalScroller = true
             scroll.scrollerStyle = .overlay
         }
    +
    +    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    +        let cell = tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? FileCell ?? FileCell()
    +        cell.show(entries[row], selected: tableView.selectedRow == row, showsHiddenFiles: showsHiddenFiles, root: root)
    +        return cell
    +    }
    +
    +    public func numberOfRows(in tableView: NSTableView) -> Int {
    +        entries.count
    +    }
    +
    +    private var showsHiddenFiles = false
     }
    diff --git a/Sources/VitraPanel/FileCell.swift b/Sources/VitraPanel/FileCell.swift
    new file mode 100644
    index 0000000..7c3e1b4
    --- /dev/null
    +++ b/Sources/VitraPanel/FileCell.swift
    @@ -0,0 +1,6 @@
    +import AppKit
    +
    +/// One entry of the file list, reused as the list scrolls.
    +final class FileCell: NSTableCellView {
    +    func show(_ entry: DirectoryListing.Entry, selected: Bool) {}
    +}
    \\ No newline at end of file
    diff --git a/Sources/VitraPanel/FileRow.swift b/Sources/VitraPanel/FileRow.swift
    deleted file mode 100644
    index 5d2e8f1..0000000
    --- a/Sources/VitraPanel/FileRow.swift
    +++ /dev/null
    @@ -1,3 +0,0 @@
    -import AppKit
    -
    -final class FileRow: NSView {}
    diff --git a/docs/screens/files.png b/docs/screens/files.png
    index 1a2b3c4..5d6e7f8 100644
    Binary files a/docs/screens/files.png and b/docs/screens/files.png differ
    """
}

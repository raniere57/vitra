import AppKit
import Foundation
import Testing
@testable import VitraApp

// MARK: - Parser

@Test func parsesAModifiedFileWithTwoHunksAndNumbersEachSide() throws {
    let diff = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -3,4 +3,5 @@ struct A {
         let a = 1
    -    let b = 2
    +    let b = 3
    +    let c = 4
         let d = 5
     }
    @@ -40,2 +41,1 @@ func tail()
    -    old()
         return
    """
    let files = UnifiedDiff.parse(diff)
    let file = try #require(files.first)
    #expect(files.count == 1)
    #expect(file.path == "Sources/A.swift")
    #expect(file.status == .modified)
    #expect(file.hunks.count == 2)
    #expect(file.hunks[0].header == "@@ -3,4 +3,5 @@ struct A {")
    #expect(file.hunks[0].lines.map(\.kind) == [.context, .removed, .added, .added, .context, .context])
    #expect(file.hunks[0].lines.map(\.old) == [3, 4, nil, nil, 5, 6])
    #expect(file.hunks[0].lines.map(\.new) == [3, nil, 4, 5, 6, 7])
    #expect(file.hunks[0].lines[1].text == "    let b = 2")
    #expect(file.hunks[1].lines.map(\.old) == [40, 41])
    #expect(file.hunks[1].lines.map(\.new) == [nil, 41])
    #expect(file.added == 2)
    #expect(file.removed == 2)
}

@Test func parsesANewFileAndItsMissingNewlineMarker() throws {
    let diff = """
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +one
    +two
    \\ No newline at end of file
    """
    let file = try #require(UnifiedDiff.parse(diff).first)
    #expect(file.path == "new.txt")
    #expect(file.status == .added)
    #expect(file.hunks[0].lines.map(\.new) == [1, 2])
    #expect(file.hunks[0].lines.map(\.missingNewline) == [false, true])
}

@Test func parsesADeletedFileUnderItsOldPath() throws {
    let diff = """
    diff --git a/gone.swift b/gone.swift
    deleted file mode 100644
    index 4444444..0000000
    --- a/gone.swift
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -import AppKit
    --- a line that starts with two dashes
    """
    let file = try #require(UnifiedDiff.parse(diff).first)
    #expect(file.path == "gone.swift")
    #expect(file.status == .deleted)
    // "--- a line…" is a removed line, not another file's header.
    #expect(file.hunks[0].lines.map(\.text) == ["import AppKit", "-- a line that starts with two dashes"])
    #expect(file.hunks[0].lines.map(\.old) == [1, 2])
}

@Test func parsesRenamesWithAndWithoutChangesAndBinaryFiles() throws {
    let diff = """
    diff --git a/old name.md b/new name.md
    similarity index 100%
    rename from old name.md
    rename to new name.md
    diff --git a/src/a.swift b/src/b.swift
    similarity index 90%
    rename from src/a.swift
    rename to src/b.swift
    index 5555555..6666666 100644
    --- a/src/a.swift
    +++ b/src/b.swift
    @@ -1 +1 @@
    -let x = 1
    +let x = 2
    diff --git a/logo.png b/logo.png
    index 7777777..8888888 100644
    Binary files a/logo.png and b/logo.png differ
    """
    let files = UnifiedDiff.parse(diff)
    #expect(files.count == 3)
    #expect(files[0].path == "new name.md")
    #expect(files[0].status == .renamed(from: "old name.md"))
    #expect(files[0].hunks.isEmpty)
    #expect(files[1].path == "src/b.swift")
    #expect(files[1].status == .renamed(from: "src/a.swift"))
    #expect(files[1].hunks[0].lines.map(\.old) == [1, nil])
    #expect(files[1].hunks[0].lines.map(\.new) == [nil, 1])
    #expect(files[2].path == "logo.png")
    #expect(files[2].isBinary)
    #expect(files[2].hunks.isEmpty)
}

// MARK: - Comments

private let anchor = ReviewAnchor(path: "a.swift", side: .new, line: 4, code: "let b = 3")

@Test func commentsAreAddedEditedAndRemovedPerRun() throws {
    let book = ReviewCommentBook()
    let first = try #require(book.add("  fix this  ", at: anchor, order: 5, run: "r1"))
    book.add("earlier line", at: ReviewAnchor(path: "a.swift", side: .old, line: 2, code: "x"), order: 1, run: "r1")
    book.add("other run", at: anchor, order: 0, run: "r2")
    #expect(book.add("   ", at: anchor, order: 0, run: "r1") == nil)

    #expect(book.comments(for: "r1").map(\.text) == ["earlier line", "fix this"])
    #expect(book.comments(for: "r2").map(\.text) == ["other run"])

    book.edit(first.id, text: "fix this properly", run: "r1")
    #expect(book.comments(for: "r1").last?.text == "fix this properly")

    book.remove(first.id, run: "r1")
    #expect(book.comments(for: "r1").map(\.text) == ["earlier line"])

    // Emptied while editing, a comment goes.
    let only = try #require(book.comments(for: "r2").first)
    book.edit(only.id, text: "", run: "r2")
    #expect(book.comments(for: "r2").isEmpty)
}

@Test func formatsCommentsAsTheWorkerReadsThem() {
    let comments = [
        ReviewComment(id: UUID(), anchor: anchor, text: "should be 2", order: 9),
        ReviewComment(id: UUID(), anchor: ReviewAnchor(path: "b \"q\".swift", side: .old, line: 7, code: "old()"), text: "keep this call", order: 2),
    ]
    #expect(ReviewNotes.format(comments) == """
    Review comments on your delivery; fix exactly these:
    <review_comments>
    <comment file="b &quot;q&quot;.swift" line="7" side="old">
    <code>old()</code>
    keep this call
    </comment>
    <comment file="a.swift" line="4" side="new">
    <code>let b = 3</code>
    should be 2
    </comment>
    </review_comments>
    """)
    #expect(ReviewNotes.count(1) == "1 comentário")
    #expect(ReviewNotes.count(3) == "3 comentários")
}

@Test func aCommentOnARemovedLinePointsAtTheOldSideAndSitsUnderIt() throws {
    let diff = """
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -10,3 +10,3 @@
     keep
    -gone
    +came
     keep too
    """
    let files = UnifiedDiff.parse(diff)
    let removed = files[0].hunks[0].lines[1]
    let added = files[0].hunks[0].lines[2]
    let oldAnchor = try #require(ReviewAnchor(path: "a.swift", line: removed))
    #expect(oldAnchor == ReviewAnchor(path: "a.swift", side: .old, line: 11, code: "gone"))
    #expect(ReviewAnchor(path: "a.swift", line: added) == ReviewAnchor(path: "a.swift", side: .new, line: 11, code: "came"))
    // Old 11 and new 11 are different lines: the comment goes under the removed one.
    #expect(!oldAnchor.isSamePlace(as: ReviewAnchor(path: "a.swift", side: .new, line: 11, code: "came")))

    let comment = ReviewComment(id: UUID(), anchor: oldAnchor, text: "why?", order: 1)
    let rows = DiffRows.build(files, comments: [comment])
    let at = try #require(rows.firstIndex(of: .comment(comment)))
    #expect(rows[at - 1] == .line(DiffLineRef(file: 0, hunk: 0, line: 1), ordinal: 1))

    let editing = DiffRows.build(files, comments: [comment], editing: DiffEditing(line: DiffLineRef(file: 0, hunk: 0, line: 1), comment: comment.id))
    #expect(editing[at] == .editor(DiffLineRef(file: 0, hunk: 0, line: 1), ordinal: 1, comment: comment))
}

@Test func aDiffPastTheLimitIsCutWithANote() {
    let body = (1...30).map { "+line \($0)" }.joined(separator: "\n")
    let files = UnifiedDiff.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1,30 @@\n" + body)
    let rows = DiffRows.build(files, limit: 10)
    #expect(rows.first == .truncated(shown: 10, total: 30))
    #expect(rows.filter { if case .line = $0 { true } else { false } }.count == 10)
    #expect(DiffRows.summary(added: 3, removed: 1, files: 1) == "+3 −1 · 1 arquivo")
}

@Test func readsTheNewRunOutOfTheRedosAnswer() {
    #expect(DeliveryRedo.newRun(in: "Started agent 9f8e7d6c: claude, edit access, redo of a1") == "9f8e7d6c")
    #expect(DeliveryRedo.newRun(in: "agent a1 is still running") == nil)
}

// MARK: - View

@MainActor
@Test func aLongLineMakesTheDiffScrollSideways() {
    let long = String(repeating: "x", count: 400)
    let files = UnifiedDiff.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+\(long)")
    let delivery = Delivery(runID: "r", label: "l", worker: "w", repository: "/tmp", branch: "b", base: "c", worktree: nil)
    let view = DiffReviewView(delivery: delivery, book: ReviewCommentBook(), isSolo: false, loads: false) { _, _ in }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView?.addFilling(view)
    view.show(files)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(view.table.bounds.width > 400 * 2)
    #expect(view.selected == DiffLineRef(file: 0, hunk: 0, line: 0))
    view.move(.down)
    #expect(view.selected == DiffLineRef(file: 0, hunk: 0, line: 1))
}

import AppKit

/// What the review does with a key, whatever key it came from.
enum DiffKey {
    case up
    case down
    case comment
    case nextFile
    case previousFile
    case back

    /// ↑ ↓ move, ⏎ comments, n and p jump between files, ⎋ goes back.
    init?(_ event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .comment
        case 53: self = .back
        default:
            switch event.charactersIgnoringModifiers {
            case "n": self = .nextFile
            case "p": self = .previousFile
            default: return nil
            }
        }
    }
}

/// The review's table, which hands its keys and its gutter clicks to the
/// review instead of acting on them the way a list would: arrows step over
/// headers and notes onto the next line of code, and a click on the numbers
/// opens a comment there.
final class DiffTable: NSTableView {
    var onKey: ((DiffKey) -> Bool)?
    /// Called with the row whose gutter was clicked; true when it was taken.
    var onGutterClick: ((Int) -> Bool)?
    var gutterWidth: CGFloat = 0

    override func keyDown(with event: NSEvent) {
        if let key = DiffKey(event), onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onKey?(.back)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0, point.x < gutterWidth, onGutterClick?(row) == true {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }
}

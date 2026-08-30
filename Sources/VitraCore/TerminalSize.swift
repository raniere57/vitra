import Foundation

/// Dimensions of a terminal, in cells and in pixels.
///
/// Pixel dimensions are not decoration: programs that draw inline images (and
/// the Kitty graphics protocol in particular) read them from `TIOCGWINSZ` to
/// size their output. Reporting zeroes silently degrades those programs, so
/// callers that know the real cell metrics should always pass them through.
public struct TerminalSize: Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16
    public let pixelWidth: UInt16
    public let pixelHeight: UInt16

    public init(columns: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        // A zero-sized terminal is meaningless and makes downstream reflow math
        // divide by zero, so clamp at the boundary instead of trusting callers.
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public static let `default` = TerminalSize(columns: 80, rows: 24)
}

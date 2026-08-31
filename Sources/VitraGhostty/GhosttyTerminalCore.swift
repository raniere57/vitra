import CGhosttyVT
import Foundation
import VitraCore

/// `TerminalCore` backed by libghostty-vt.
///
/// The C handle is not thread-safe and libghostty explicitly requires callers to
/// serialize access, so every method here must run on the session's own queue.
/// Callbacks fire synchronously inside `feed` and must not re-enter the terminal.
/// Serialization is the caller's responsibility, so this is `@unchecked Sendable`:
/// the compiler cannot see the queue discipline that makes it safe.
public final class GhosttyTerminalCore: TerminalCore, @unchecked Sendable {
    let handle: GhosttyTerminal
    let renderReader: RenderStateReader
    private let keyEncoder: KeyEncoder
    public private(set) var size: TerminalSize

    /// Bytes the emulator wants sent back to the child (device status reports,
    /// device attributes, cursor position queries). Dropping these makes programs
    /// that probe the terminal hang waiting for an answer.
    public var onWritePTY: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    public var onTitleChanged: (@Sendable (String) -> Void)?
    public var onBell: (@Sendable () -> Void)?

    public init(size: TerminalSize) throws {
        var terminal: GhosttyTerminal?
        let result = ghostty_terminal_new(nil, &terminal, size.columns, size.rows)
        guard result == GHOSTTY_SUCCESS, let terminal else {
            throw TerminalCoreError.operationFailed("terminal_new", code: result.rawValue)
        }
        self.handle = terminal
        self.size = size
        self.renderReader = try RenderStateReader()
        self.keyEncoder = try KeyEncoder()

        installCallbacks()
    }

    deinit {
        ghostty_terminal_free(handle)
    }

    // MARK: - TerminalCore

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(handle, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    public func resize(to size: TerminalSize) throws {
        let cellWidth = size.columns > 0 ? UInt32(size.pixelWidth) / UInt32(size.columns) : 0
        let cellHeight = size.rows > 0 ? UInt32(size.pixelHeight) / UInt32(size.rows) : 0
        let result = ghostty_terminal_resize(handle, size.columns, size.rows, cellWidth, cellHeight)
        guard result == GHOSTTY_SUCCESS else {
            throw TerminalCoreError.operationFailed("terminal_resize", code: result.rawValue)
        }
        self.size = size
    }

    public func scrollViewport(lines: Int) {
        guard lines != 0 else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = lines
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    public func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    public func encode(_ event: KeyEvent) -> [UInt8] {
        keyEncoder.encode(event, terminal: handle)
    }

    public func updateSnapshot(_ snapshot: RenderSnapshot) throws -> Bool {
        try renderReader.update(from: handle, into: snapshot)
    }

    public func screenText() -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = false
        options.trim = true
        options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size

        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, handle, options) == GHOSTTY_SUCCESS,
              let formatter
        else { return "" }
        defer { ghostty_formatter_free(formatter) }

        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &pointer, &length) == GHOSTTY_SUCCESS,
              let pointer
        else { return "" }
        defer { ghostty_free(nil, pointer, length) }

        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    // MARK: - Callbacks

    private func installCallbacks() {
        // Unretained: the terminal handle is owned by this object and freed in
        // deinit, so no callback can outlive the instance it points back to.
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)

        let writePTY: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data else { return }
            let core = Unmanaged<GhosttyTerminalCore>.fromOpaque(userdata).takeUnretainedValue()
            core.onWritePTY?(UnsafeRawBufferPointer(start: data, count: length))
        }
        _ = ghostty_terminal_set(
            handle,
            GHOSTTY_TERMINAL_OPT_WRITE_PTY,
            unsafeBitCast(writePTY, to: UnsafeRawPointer.self)
        )

        let bell: GhosttyTerminalBellFn = { _, userdata in
            guard let userdata else { return }
            Unmanaged<GhosttyTerminalCore>.fromOpaque(userdata).takeUnretainedValue().onBell?()
        }
        _ = ghostty_terminal_set(
            handle,
            GHOSTTY_TERMINAL_OPT_BELL,
            unsafeBitCast(bell, to: UnsafeRawPointer.self)
        )

        // The title callback carries no payload; the new title is read back out
        // of the terminal once it fires.
        let titleChanged: GhosttyTerminalTitleChangedFn = { terminal, userdata in
            guard let userdata else { return }
            let core = Unmanaged<GhosttyTerminalCore>.fromOpaque(userdata).takeUnretainedValue()
            core.onTitleChanged?(readTitle(terminal))
        }
        _ = ghostty_terminal_set(
            handle,
            GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
            unsafeBitCast(titleChanged, to: UnsafeRawPointer.self)
        )
    }
}

private func readTitle(_ terminal: GhosttyTerminal?) -> String {
    var string = GhosttyString()
    guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &string) == GHOSTTY_SUCCESS,
          let pointer = string.ptr
    else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: string.len), as: UTF8.self)
}

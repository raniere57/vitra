import Darwin

/// Finds `ESC ] 7337 ; <payload> ST` in the terminal's output stream.
///
/// libghostty reports unsupported sequences through its unknown-sequence
/// callback, but at the pinned commit that callback covers APC only — an OSC it
/// does not recognise is parsed and dropped without ever reaching the embedder.
/// So the sequence is picked up here, before the bytes are fed to the core.
///
/// Nothing is removed from the stream: libghostty consumes the whole sequence
/// and prints none of it, so the terminal shows no artefact either way.
public struct OSCScanner: Sendable {
    /// The introducer after `ESC ]`, matched byte by byte.
    private static let prefix = Array("7337;".utf8)

    /// Longest payload accepted before the sequence is abandoned.
    ///
    /// A path cannot plausibly be longer, and without a cap a stray `ESC ]` in
    /// binary output would make the scanner buffer without bound.
    private static let payloadLimit = 4096

    private enum State {
        case idle
        /// Seen `ESC`, waiting for `]`.
        case escape
        /// Matching `7337;`, with the number of bytes matched so far.
        case introducer(Int)
        /// Collecting the payload.
        case payload
        /// Seen `ESC` inside the payload: `ESC \` ends the sequence.
        case payloadEscape
    }

    private var state: State = .idle
    private var payload: [UInt8] = []

    public init() {}

    /// Feeds `bytes`, calling `onCommand` once per complete sequence.
    ///
    /// The payload is the text between `7337;` and the terminator, decoded as
    /// UTF-8; invalid UTF-8 is dropped rather than repaired.
    public mutating func scan(
        _ bytes: UnsafeRawBufferPointer,
        _ onCommand: (String) -> Void
    ) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        var index = 0

        while index < bytes.count {
            if case .idle = state {
                // Fast path: almost all output has no escape byte at all, and
                // memchr is a great deal quicker than a Swift loop over 100 MB.
                guard let hit = memchr(base + index, 0x1B, bytes.count - index) else { return }
                index = base.distance(to: hit) + 1
                state = .escape
                continue
            }

            let byte = bytes.loadUnaligned(fromByteOffset: index, as: UInt8.self)
            index += 1
            step(byte, onCommand)
        }
    }

    private mutating func step(_ byte: UInt8, _ onCommand: (String) -> Void) {
        switch state {
        case .idle:
            if byte == 0x1B { state = .escape }

        case .escape:
            // `ESC ]` starts an OSC; another ESC restarts the match.
            if byte == 0x5D { state = .introducer(0) } else { state = byte == 0x1B ? .escape : .idle }

        case let .introducer(matched):
            if byte == Self.prefix[matched] {
                let next = matched + 1
                if next == Self.prefix.count {
                    payload.removeAll(keepingCapacity: true)
                    state = .payload
                } else {
                    state = .introducer(next)
                }
            } else {
                // Some other OSC. libghostty handles it; this scanner steps back.
                state = byte == 0x1B ? .escape : .idle
            }

        case .payload:
            switch byte {
            case 0x07: finish(onCommand)          // BEL terminates
            case 0x1B: state = .payloadEscape     // maybe ST
            case 0x18, 0x1A: abort()              // CAN and SUB cancel
            default:
                payload.append(byte)
                if payload.count > Self.payloadLimit { abort() }
            }

        case .payloadEscape:
            // ESC \ is ST. Anything else aborts: a sequence cannot contain a
            // bare ESC, so the stream has moved on to something else.
            if byte == 0x5C { finish(onCommand) } else { abort(); step(byte, onCommand) }
        }
    }

    private mutating func finish(_ onCommand: (String) -> Void) {
        if let text = String(bytes: payload, encoding: .utf8) { onCommand(text) }
        abort()
    }

    private mutating func abort() {
        payload.removeAll(keepingCapacity: true)
        state = .idle
    }
}

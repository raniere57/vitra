import CGhosttyVT
import Foundation
import VitraCore

/// Encodes key events using libghostty's encoder.
///
/// Key encoding is not a lookup table: it depends on terminal modes that change
/// at runtime (application cursor keys, the Kitty keyboard protocol flags,
/// modifyOtherKeys). Letting libghostty own it is what makes those protocols
/// work without reimplementing them.
final class KeyEncoder {
    private let encoder: GhosttyKeyEncoder
    private let event: GhosttyKeyEvent
    private var buffer = [CChar](repeating: 0, count: 128)

    /// Stable storage for the event's UTF-8 text.
    ///
    /// The key event borrows the pointer rather than copying it, so the bytes
    /// must stay alive and at a fixed address until encoding is done. A Swift
    /// String's own buffer is only valid inside `withUTF8`.
    private let textStorage = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 64)

    init() throws {
        var encoder: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS, let encoder else {
            throw TerminalCoreError.allocationFailed
        }
        self.encoder = encoder

        // The event object is reused across keystrokes; only its fields change.
        var event: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS, let event else {
            ghostty_key_encoder_free(encoder)
            throw TerminalCoreError.allocationFailed
        }
        self.event = event
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
        textStorage.deallocate()
    }

    func encode(_ key: KeyEvent, terminal: GhosttyTerminal) -> [UInt8] {
        // Terminal modes change as programs run, so the encoder is resynced from
        // the terminal on every keystroke rather than configured once.
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)

        ghostty_key_event_set_action(event, key.action.ghostty)
        ghostty_key_event_set_key(event, Self.ghosttyKey(forVirtualKeyCode: key.keyCode))
        ghostty_key_event_set_mods(event, key.modifiers.ghostty)
        ghostty_key_event_set_unshifted_codepoint(event, key.unshiftedCodepoint)

        setText(key.text)

        var written = 0
        let result = buffer.withUnsafeMutableBufferPointer { out in
            ghostty_key_encoder_encode(encoder, event, out.baseAddress, out.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return [] }
        return buffer[0 ..< written].map { UInt8(bitPattern: $0) }
    }

    /// Copies `text` into stable storage and points the event at it.
    ///
    /// Control characters and the private-use codepoints AppKit produces for
    /// function keys are rejected: the encoder documents that it derives those
    /// from the logical key, and passing them as text produces garbage.
    private func setText(_ text: String) {
        var count = 0
        for byte in text.utf8 {
            guard count < textStorage.count else { break }
            textStorage[count] = CChar(bitPattern: byte)
            count += 1
        }

        let isControlOrFunctionKey = text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || (0xF700 ... 0xF8FF).contains(scalar.value)
        }

        if count == 0 || isControlOrFunctionKey {
            ghostty_key_event_set_utf8(event, nil, 0)
        } else {
            ghostty_key_event_set_utf8(event, textStorage.baseAddress, count)
        }
    }

    /// Maps a macOS virtual key code to libghostty's W3C-style physical key.
    ///
    /// The virtual key codes are the Carbon `kVK_*` values. They are stable
    /// across macOS releases and independent of the active keyboard layout,
    /// which is exactly what the encoder wants.
    private static func ghosttyKey(forVirtualKeyCode code: UInt16) -> GhosttyKey {
        switch code {
        // Letters
        case 0x00: GHOSTTY_KEY_A
        case 0x0B: GHOSTTY_KEY_B
        case 0x08: GHOSTTY_KEY_C
        case 0x02: GHOSTTY_KEY_D
        case 0x0E: GHOSTTY_KEY_E
        case 0x03: GHOSTTY_KEY_F
        case 0x05: GHOSTTY_KEY_G
        case 0x04: GHOSTTY_KEY_H
        case 0x22: GHOSTTY_KEY_I
        case 0x26: GHOSTTY_KEY_J
        case 0x28: GHOSTTY_KEY_K
        case 0x25: GHOSTTY_KEY_L
        case 0x2E: GHOSTTY_KEY_M
        case 0x2D: GHOSTTY_KEY_N
        case 0x1F: GHOSTTY_KEY_O
        case 0x23: GHOSTTY_KEY_P
        case 0x0C: GHOSTTY_KEY_Q
        case 0x0F: GHOSTTY_KEY_R
        case 0x01: GHOSTTY_KEY_S
        case 0x11: GHOSTTY_KEY_T
        case 0x20: GHOSTTY_KEY_U
        case 0x09: GHOSTTY_KEY_V
        case 0x0D: GHOSTTY_KEY_W
        case 0x07: GHOSTTY_KEY_X
        case 0x10: GHOSTTY_KEY_Y
        case 0x06: GHOSTTY_KEY_Z

        // Digits
        case 0x1D: GHOSTTY_KEY_DIGIT_0
        case 0x12: GHOSTTY_KEY_DIGIT_1
        case 0x13: GHOSTTY_KEY_DIGIT_2
        case 0x14: GHOSTTY_KEY_DIGIT_3
        case 0x15: GHOSTTY_KEY_DIGIT_4
        case 0x17: GHOSTTY_KEY_DIGIT_5
        case 0x16: GHOSTTY_KEY_DIGIT_6
        case 0x1A: GHOSTTY_KEY_DIGIT_7
        case 0x1C: GHOSTTY_KEY_DIGIT_8
        case 0x19: GHOSTTY_KEY_DIGIT_9

        // Punctuation
        case 0x18: GHOSTTY_KEY_EQUAL
        case 0x1B: GHOSTTY_KEY_MINUS
        case 0x21: GHOSTTY_KEY_BRACKET_LEFT
        case 0x1E: GHOSTTY_KEY_BRACKET_RIGHT
        case 0x27: GHOSTTY_KEY_QUOTE
        case 0x29: GHOSTTY_KEY_SEMICOLON
        case 0x2A: GHOSTTY_KEY_BACKSLASH
        case 0x2B: GHOSTTY_KEY_COMMA
        case 0x2C: GHOSTTY_KEY_SLASH
        case 0x2F: GHOSTTY_KEY_PERIOD
        case 0x32: GHOSTTY_KEY_BACKQUOTE
        case 0x0A: GHOSTTY_KEY_INTL_BACKSLASH
        case 0x5D: GHOSTTY_KEY_INTL_YEN
        case 0x5E: GHOSTTY_KEY_INTL_RO

        // Control keys
        case 0x24: GHOSTTY_KEY_ENTER
        case 0x30: GHOSTTY_KEY_TAB
        case 0x31: GHOSTTY_KEY_SPACE
        case 0x33: GHOSTTY_KEY_BACKSPACE
        case 0x35: GHOSTTY_KEY_ESCAPE
        case 0x39: GHOSTTY_KEY_CAPS_LOCK
        case 0x3F: GHOSTTY_KEY_FN
        case 0x6E: GHOSTTY_KEY_CONTEXT_MENU

        // Modifiers
        case 0x37: GHOSTTY_KEY_META_LEFT
        case 0x36: GHOSTTY_KEY_META_RIGHT
        case 0x38: GHOSTTY_KEY_SHIFT_LEFT
        case 0x3C: GHOSTTY_KEY_SHIFT_RIGHT
        case 0x3A: GHOSTTY_KEY_ALT_LEFT
        case 0x3D: GHOSTTY_KEY_ALT_RIGHT
        case 0x3B: GHOSTTY_KEY_CONTROL_LEFT
        case 0x3E: GHOSTTY_KEY_CONTROL_RIGHT

        // Navigation
        case 0x7B: GHOSTTY_KEY_ARROW_LEFT
        case 0x7C: GHOSTTY_KEY_ARROW_RIGHT
        case 0x7D: GHOSTTY_KEY_ARROW_DOWN
        case 0x7E: GHOSTTY_KEY_ARROW_UP
        case 0x73: GHOSTTY_KEY_HOME
        case 0x77: GHOSTTY_KEY_END
        case 0x74: GHOSTTY_KEY_PAGE_UP
        case 0x79: GHOSTTY_KEY_PAGE_DOWN
        case 0x75: GHOSTTY_KEY_DELETE
        case 0x72: GHOSTTY_KEY_INSERT

        // Function keys
        case 0x7A: GHOSTTY_KEY_F1
        case 0x78: GHOSTTY_KEY_F2
        case 0x63: GHOSTTY_KEY_F3
        case 0x76: GHOSTTY_KEY_F4
        case 0x60: GHOSTTY_KEY_F5
        case 0x61: GHOSTTY_KEY_F6
        case 0x62: GHOSTTY_KEY_F7
        case 0x64: GHOSTTY_KEY_F8
        case 0x65: GHOSTTY_KEY_F9
        case 0x6D: GHOSTTY_KEY_F10
        case 0x67: GHOSTTY_KEY_F11
        case 0x6F: GHOSTTY_KEY_F12
        case 0x69: GHOSTTY_KEY_F13
        case 0x6B: GHOSTTY_KEY_F14
        case 0x71: GHOSTTY_KEY_F15
        case 0x6A: GHOSTTY_KEY_F16
        case 0x40: GHOSTTY_KEY_F17
        case 0x4F: GHOSTTY_KEY_F18
        case 0x50: GHOSTTY_KEY_F19
        case 0x5A: GHOSTTY_KEY_F20

        // Numpad
        case 0x52: GHOSTTY_KEY_NUMPAD_0
        case 0x53: GHOSTTY_KEY_NUMPAD_1
        case 0x54: GHOSTTY_KEY_NUMPAD_2
        case 0x55: GHOSTTY_KEY_NUMPAD_3
        case 0x56: GHOSTTY_KEY_NUMPAD_4
        case 0x57: GHOSTTY_KEY_NUMPAD_5
        case 0x58: GHOSTTY_KEY_NUMPAD_6
        case 0x59: GHOSTTY_KEY_NUMPAD_7
        case 0x5B: GHOSTTY_KEY_NUMPAD_8
        case 0x5C: GHOSTTY_KEY_NUMPAD_9
        case 0x41: GHOSTTY_KEY_NUMPAD_DECIMAL
        case 0x43: GHOSTTY_KEY_NUMPAD_MULTIPLY
        case 0x45: GHOSTTY_KEY_NUMPAD_ADD
        case 0x4B: GHOSTTY_KEY_NUMPAD_DIVIDE
        case 0x4C: GHOSTTY_KEY_NUMPAD_ENTER
        case 0x4E: GHOSTTY_KEY_NUMPAD_SUBTRACT
        case 0x51: GHOSTTY_KEY_NUMPAD_EQUAL
        case 0x47: GHOSTTY_KEY_NUMPAD_CLEAR
        case 0x5F: GHOSTTY_KEY_NUMPAD_COMMA

        // Media and system keys the terminal never sees as text.
        case 0x48: GHOSTTY_KEY_AUDIO_VOLUME_UP
        case 0x49: GHOSTTY_KEY_AUDIO_VOLUME_DOWN
        case 0x4A: GHOSTTY_KEY_AUDIO_VOLUME_MUTE

        // Unmapped keys still encode correctly when the layout produced text.
        default: GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}

private extension KeyEvent.Action {
    var ghostty: GhosttyKeyAction {
        switch self {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        case .repeated: GHOSTTY_KEY_ACTION_REPEAT
        }
    }
}

private extension KeyModifiers {
    var ghostty: GhosttyMods {
        var mods: Int32 = 0
        if contains(.shift) { mods |= GHOSTTY_MODS_SHIFT }
        if contains(.control) { mods |= GHOSTTY_MODS_CTRL }
        if contains(.option) { mods |= GHOSTTY_MODS_ALT }
        if contains(.command) { mods |= GHOSTTY_MODS_SUPER }
        if contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS_LOCK }
        return GhosttyMods(truncatingIfNeeded: mods)
    }
}

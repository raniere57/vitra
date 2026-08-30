import Foundation

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    /// Set when the pressed modifier was the right-hand one.
    public static let rightSide = KeyModifiers(rawValue: 1 << 5)
}

/// A keyboard event on its way to the terminal.
///
/// The key is identified by its macOS virtual key code rather than a bespoke
/// enum: the code is layout-independent, AppKit hands it over directly, and
/// translating it into whatever the VT engine wants is the engine adapter's job.
public struct KeyEvent: Sendable {
    public enum Action: Sendable {
        case press
        case release
        case repeated
    }

    public var action: Action
    /// `NSEvent.keyCode`.
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// The text the keyboard layout produced, empty for keys that produce none.
    public var text: String
    /// The codepoint this key produces with no modifiers applied, used by the
    /// Kitty keyboard protocol to report the base key.
    public var unshiftedCodepoint: UInt32

    public init(
        action: Action = .press,
        keyCode: UInt16,
        modifiers: KeyModifiers = [],
        text: String = "",
        unshiftedCodepoint: UInt32 = 0
    ) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
    }
}

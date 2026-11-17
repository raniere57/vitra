import Testing
import VitraCore
@testable import VitraGhostty

private func encoded(
    keyCode: UInt16,
    modifiers: KeyModifiers = [],
    text: String = "",
    unshifted: UInt32 = 0,
    after setup: String = ""
) throws -> String {
    let core = try GhosttyTerminalCore(size: .default)
    if !setup.isEmpty { core.feed(setup) }
    let bytes = core.encode(KeyEvent(
        keyCode: keyCode,
        modifiers: modifiers,
        text: text,
        unshiftedCodepoint: unshifted
    ))
    return String(decoding: bytes, as: UTF8.self)
}

// macOS virtual key codes.
private let keyA: UInt16 = 0x00
private let keyC: UInt16 = 0x08
private let keyReturn: UInt16 = 0x24
private let keyTab: UInt16 = 0x30
private let keyEscape: UInt16 = 0x35
private let keyBackspace: UInt16 = 0x33
private let keyArrowUp: UInt16 = 0x7E
private let keyArrowLeft: UInt16 = 0x7B
private let keyF1: UInt16 = 0x7A
private let keyHome: UInt16 = 0x73

@Test func plainCharacterEncodesAsItsText() throws {
    #expect(try encoded(keyCode: keyA, text: "a", unshifted: 0x61) == "a")
}

@Test func shiftedCharacterUsesTheLayoutText() throws {
    // The layout, not the terminal, decides that shift+a is "A".
    #expect(try encoded(keyCode: keyA, modifiers: .shift, text: "A", unshifted: 0x61) == "A")
}

@Test func controlLetterEncodesAsAControlCode() throws {
    // Ctrl-C is 0x03. Getting this wrong makes it impossible to interrupt anything.
    #expect(try encoded(keyCode: keyC, modifiers: .control, unshifted: 0x63) == "\u{03}")
}

@Test func namedKeysEncodeToTheirControlCodes() throws {
    #expect(try encoded(keyCode: keyReturn) == "\r")
    #expect(try encoded(keyCode: keyTab) == "\t")
    #expect(try encoded(keyCode: keyEscape) == "\u{1B}")
    #expect(try encoded(keyCode: keyBackspace) == "\u{7F}")
}

@Test func arrowKeysUseNormalCursorSequences() throws {
    #expect(try encoded(keyCode: keyArrowUp) == "\u{1B}[A")
    #expect(try encoded(keyCode: keyArrowLeft) == "\u{1B}[D")
}

@Test func arrowKeysFollowApplicationCursorMode() throws {
    // DECCKM. Full-screen programs switch this on and then expect SS3 sequences;
    // ignoring the mode breaks arrow keys inside vim and less.
    #expect(try encoded(keyCode: keyArrowUp, after: "\u{1B}[?1h") == "\u{1B}OA")
}

@Test func modifiedArrowKeysCarryTheModifierParameter() throws {
    // Shift+Up is CSI 1;2A. The "2" is the modifier encoding.
    #expect(try encoded(keyCode: keyArrowUp, modifiers: .shift) == "\u{1B}[1;2A")
}

@Test func functionAndNavigationKeysEncode() throws {
    #expect(try encoded(keyCode: keyF1) == "\u{1B}OP")
    #expect(try encoded(keyCode: keyHome) == "\u{1B}[H")
}

@Test func modifierKeyPressesProduceNothingByDefault() throws {
    // Pressing shift on its own must not send bytes; only the Kitty keyboard
    // protocol reports modifier keys, and it is off by default.
    #expect(try encoded(keyCode: 0x38) == "")
}

@Test func commandKeyIsNotSentToTheTerminal() throws {
    // Cmd is the app's own modifier: Cmd-C must reach the menu, not the shell.
    #expect(try encoded(keyCode: keyC, modifiers: .command, unshifted: 0x63) == "")
}

/// What "enviar agora" sends: Claude Code's Ctrl+Return, as the terminal
/// encodes it in each keyboard mode the program may have asked for.
@Test func controlReturnIsToldApartFromReturnOnceTheProgramAsksForIt() throws {
    let plain = try encoded(keyCode: keyReturn, modifiers: .control, text: "\r", unshifted: 13)
    let kitty = try encoded(keyCode: keyReturn, modifiers: .control, text: "\r", unshifted: 13, after: "\u{1b}[>1u")
    let other = try encoded(keyCode: keyReturn, modifiers: .control, text: "\r", unshifted: 13, after: "\u{1b}[>4;2m")
    let chordX = try encoded(keyCode: 7, modifiers: .control, text: "\u{18}", unshifted: 120)
    let chordXKitty = try encoded(keyCode: 7, modifiers: .control, text: "\u{18}", unshifted: 120, after: "\u{1b}[>1u")
    #expect(plain == "\u{1b}[27;5;13~")
    #expect(other == "\u{1b}[27;5;13~")
    // The chord's keys change shape too: sent as raw control bytes they are
    // not what a program in the Kitty protocol is listening for.
    #expect(chordX == "\u{18}")
    #expect(chordXKitty == "\u{1b}[120;5u")
    #expect(kitty == "\u{1b}[13;5u")
}

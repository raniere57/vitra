import Foundation
import Testing
@testable import VitraCore

@Suite("TOML")
struct TOMLTests {
    @Test func keysAndScalarsAreRead() throws {
        let parsed = try TOML.parse("""
        font = "Menlo"
        size = 13
        opacity = 0.92
        blur = true
        """)
        #expect(parsed["font"]?.stringValue == "Menlo")
        #expect(parsed["size"]?.intValue == 13)
        #expect(parsed["opacity"]?.doubleValue == 0.92)
        #expect(parsed["blur"]?.boolValue == true)
    }

    @Test func tablesNestByTheirHeader() throws {
        let parsed = try TOML.parse("""
        [window]
        padding = 8

        [theme.dark]
        background = "#101014"
        """)
        #expect(parsed["window"]?.tableValue?["padding"]?.intValue == 8)
        #expect(parsed["theme"]?.tableValue?["dark"]?.tableValue?["background"]?.stringValue == "#101014")
    }

    @Test func arraysKeepTheirOrder() throws {
        let parsed = try TOML.parse("""
        palette = ["#000000", "#ff0000", "#00ff00"]
        empty = []
        """)
        #expect(parsed["palette"]?.arrayValue?.count == 3)
        #expect(parsed["palette"]?.arrayValue?[1].stringValue == "#ff0000")
        #expect(parsed["empty"]?.arrayValue?.isEmpty == true)
    }

    /// A `#` is only a comment outside a string, and a config file full of
    /// colour codes is the reason this matters.
    @Test func hashesInsideStringsAreNotComments() throws {
        let parsed = try TOML.parse("""
        background = "#101014"   # the dark surface
        cursor = '#ffffff'
        """)
        #expect(parsed["background"]?.stringValue == "#101014")
        #expect(parsed["cursor"]?.stringValue == "#ffffff")
    }

    @Test func escapesAreUnwoundInBasicStringsOnly() throws {
        let parsed = try TOML.parse("""
        basic = "a\\tb"
        literal = 'a\\tb'
        """)
        #expect(parsed["basic"]?.stringValue == "a\tb")
        #expect(parsed["literal"]?.stringValue == "a\\tb")
    }

    @Test func blankLinesAndCommentsAreSkipped() throws {
        let parsed = try TOML.parse("""
        # a header comment

           font = "SF Mono"

        # trailing
        """)
        #expect(parsed.count == 1)
        #expect(parsed["font"]?.stringValue == "SF Mono")
    }

    @Test func numbersMayCarryDigitSeparators() throws {
        let parsed = try TOML.parse("scrollback = 10_000")
        #expect(parsed["scrollback"]?.intValue == 10_000)
    }

    @Test func aBrokenLineSaysWhichLineItIs() {
        #expect(throws: TOML.ParseError.self) {
            _ = try TOML.parse("""
            font = "Menlo"
            this line is not a pair
            """)
        }

        do {
            _ = try TOML.parse("ok = 1\n[unterminated\n")
            Issue.record("expected a parse error")
        } catch let error as TOML.ParseError {
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

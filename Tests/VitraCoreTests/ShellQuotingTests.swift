import Testing
@testable import VitraCore

@Test func simplePathsAreLeftAlone() {
    #expect(ShellQuoting.quote("/Users/me/notes.txt") == "/Users/me/notes.txt")
    #expect(ShellQuoting.quote("/tmp/a-b_c.2.png") == "/tmp/a-b_c.2.png")
}

@Test func spacesForceQuoting() {
    #expect(ShellQuoting.quote("/Users/me/My Documents/a.png") == "'/Users/me/My Documents/a.png'")
}

@Test func singleQuotesAreEscapedOutOfTheQuotedString() {
    // The POSIX idiom: close, emit an escaped quote, reopen.
    #expect(ShellQuoting.quote("/tmp/it's here.png") == "'/tmp/it'\\''s here.png'")
}

@Test func shellMetacharactersAreNeutralised() {
    // Every one of these would otherwise be interpreted rather than read.
    for path in ["/tmp/$HOME.png", "/tmp/a`b`.png", "/tmp/a;rm -rf /.png", "/tmp/a*.png", "/tmp/a|b.png"] {
        let quoted = ShellQuoting.quote(path)
        #expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"), "\(path) should be quoted")
    }
}

@Test func newlinesInFilenamesAreQuoted() {
    // Legal on macOS, and catastrophic unquoted: it becomes two command lines.
    let quoted = ShellQuoting.quote("/tmp/two\nlines.png")
    #expect(quoted.hasPrefix("'"))
    #expect(quoted.contains("\n"))
}

@Test func accentedPathsAreQuotedNotMangled() {
    // macOS stores filenames decomposed (NFD); the bytes must pass through
    // untouched or the path stops resolving.
    let decomposed = "/Users/me/Área de Trabalho/café.png"
    let quoted = ShellQuoting.quote(decomposed)
    #expect(quoted == "'\(decomposed)'")
}

@Test func emptyPathBecomesAnEmptyArgument() {
    #expect(ShellQuoting.quote("") == "''")
}

@Test func multiplePathsAreJoinedAndQuotedIndividually() {
    let joined = ShellQuoting.join(["/tmp/a.png", "/tmp/b c.png"])
    #expect(joined == "/tmp/a.png '/tmp/b c.png'")
}

import Testing
@testable import VitraApp

/// The find in the conversation: rows of the terminal's text in, cells out.
struct ConversationSearchTests {
    private func rows(_ lines: [String], wrapping: Set<Int> = []) -> [ConversationSearch.Row] {
        lines.enumerated().map { .init(text: $1, wraps: wrapping.contains($0)) }
    }

    @Test func findsEveryMatchWithItsColumns() throws {
        let found = try #require(ConversationSearch.matches(of: "ok", in: rows(["ok, ok", "", "not ok"])))
        #expect(found.map(\.spans) == [
            [.init(row: 0, columns: 0 ..< 2)],
            [.init(row: 0, columns: 4 ..< 6)],
            [.init(row: 2, columns: 4 ..< 6)],
        ])
    }

    @Test func ignoresCaseAndAccents() throws {
        let found = try #require(ConversationSearch.matches(of: "relatorio", in: rows(["o Relatório", "RELATORIO", "relatorio-45"])))
        #expect(found.count == 3)
        #expect(found[0].spans == [.init(row: 0, columns: 2 ..< 11)])
        // And the other way round: the accent typed, plain text found.
        #expect(ConversationSearch.matches(of: "RELATÓRIO", in: rows(["relatorio"]))?.count == 1)
    }

    @Test func decomposedAccentsAreOneCell() throws {
        let found = try #require(ConversationSearch.matches(of: "xito", in: rows(["e\u{301}xito"])))
        #expect(found.first?.spans == [.init(row: 0, columns: 1 ..< 5)])
    }

    @Test func wideCharactersTakeTwoCells() throws {
        let found = try #require(ConversationSearch.matches(of: "ok", in: rows(["日本 ok"])))
        #expect(found.first?.spans == [.init(row: 0, columns: 5 ..< 7)])
        let wide = try #require(ConversationSearch.matches(of: "本", in: rows(["日本"])))
        #expect(wide.first?.spans == [.init(row: 0, columns: 2 ..< 4)])
        #expect(ConversationSearch.width(of: "🙂") == 2)
        #expect(ConversationSearch.width(of: "é") == 1)
    }

    @Test func matchesAcrossASoftWrap() throws {
        let found = try #require(ConversationSearch.matches(of: "maestro", in: rows(["o mae", "stro"], wrapping: [0])))
        #expect(found.first?.spans == [.init(row: 0, columns: 2 ..< 5), .init(row: 1, columns: 0 ..< 4)])
        // Not across a hard line break.
        #expect(ConversationSearch.matches(of: "maestro", in: rows(["o mae", "stro"]))?.isEmpty == true)
    }

    @Test func rowsWrapWhenTheyFillThePane() {
        let made = ConversationSearch.rows(fromScreenText: "abcde\nfg\n日本語\nend", columns: 5)
        #expect(made.map(\.wraps) == [true, false, true, false])
        #expect(made.map(\.text) == ["abcde", "fg", "日本語", "end"])
    }

    @Test func emptyQueryFindsNothing() {
        #expect(ConversationSearch.matches(of: "", in: rows(["anything"])) == [])
    }

    @Test func cancelledSearchReturnsNil() async {
        let rows = rows(["a"])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ConversationSearch.matches(of: "a", in: rows)
        }
        #expect(await task.value == nil)
    }

    @Test @MainActor func counterReadsInPortuguese() {
        #expect(ConversationFind.counter(current: 2, total: 17, hasQuery: true) == "3 de 17")
        #expect(ConversationFind.counter(current: nil, total: 0, hasQuery: true) == "nenhuma")
        #expect(ConversationFind.counter(current: nil, total: 0, hasQuery: false) == nil)
    }
}

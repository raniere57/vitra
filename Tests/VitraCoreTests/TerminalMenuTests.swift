import Testing
@testable import VitraCore

@Suite("The menu at the bottom of Claude Code's screen, read to be answered elsewhere")
struct TerminalMenuTests {
    private func menu(_ screen: String) -> TerminalMenu? {
        TerminalMenu.read(rows: screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    @Test func aQuestionGivesItsTitleOptionsAndDetails() throws {
        let found = try #require(menu("""
        ⏺ Vou perguntar.
        ──────────────────────────
        ←  ☐ Cor  ☐ Frutas  ✔ Submit  →

        Qual cor?

        ❯ 1. Azul
             Cor do céu
          2. Verde
             Cor da grama
          3. Type something.
        ──────────────────────────
          4. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """))
        #expect(found.title == "Qual cor?")
        #expect(found.options.map(\.label) == ["Azul", "Verde", "Type something.", "Chat about this"])
        #expect(found.options[0].detail == "Cor do céu")
        #expect(found.hasFooter && !found.isMultiple)
        #expect(found.freeText?.number == 3)
    }

    @Test func aMultipleChoiceQuestionSaysWhatIsTicked() throws {
        let found = try #require(menu("""
        Quais frutas?
        ❯ 1. [✔] Banana
                 Fruta amarela
          2. [ ] Manga
          3. [ ] Type something
             Submit
        ──────────
          4. Chat about this
        Enter to select · Esc to cancel
        """))
        #expect(found.isMultiple)
        #expect(found.options.map(\.isChecked) == [true, false, false, nil])
        #expect(found.options[0].label == "Banana" && found.options[0].detail == "Fruta amarela")
        #expect(found.freeText == nil)
    }

    @Test func aPermissionPromptIsAMenuToo() throws {
        let found = try #require(menu("""
        ⏺ Bash(rm -rf build)
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for rm commands
           3. No, and tell Claude what to do differently (esc)
        """))
        #expect(found.title == "Do you want to proceed?")
        #expect(found.options.count == 3)
    }

    @Test func aNumberedListInProseIsNotAMenu() {
        #expect(menu("⏺ Os passos:\n  1. Ler\n  2. Escrever\n\n❯ \n") == nil)
        #expect(menu("❯ 1. Yes\n  2. No\n⏺ a\n⏺ b\n⏺ c\n⏺ d\n⏺ e") == nil)
        #expect(menu("❯ 2. Só a segunda\n  3. E a terceira") == nil)
    }
}

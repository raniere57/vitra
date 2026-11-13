import AppKit
import Testing
@testable import VitraApp

/// The shortcut table is the one source the menu bar and the sheet are built
/// from; these hold it to that.
@MainActor
struct ShortcutsTests {
    private var chords: [Shortcut.Chord] {
        Shortcut.table.flatMap { [$0.chord].compactMap { $0 } + $0.alternates }
    }

    @Test func everyChordIsUnique() {
        #expect(Set(chords).count == chords.count)
    }

    @Test func menuBarIsBuiltFromTheTable() {
        let bar = Shortcut.makeMenuBar()
        #expect(bar.items.map(\.title) == Shortcut.Menu.allCases.map(\.rawValue))
        let items = bar.items.compactMap(\.submenu).flatMap(\.items).filter { !$0.isSeparatorItem }
        #expect(items.count == Shortcut.table.count + Shortcut.table.flatMap(\.alternates).count)
        for shortcut in Shortcut.table {
            let item = items.first { $0.title == shortcut.title && $0.action == shortcut.action && $0.tag == shortcut.tag && !$0.isHidden }
            #expect(item != nil, "\(shortcut.title) is not in the menu")
            #expect(item?.keyEquivalent == (shortcut.chord?.key ?? ""))
            if let chord = shortcut.chord { #expect(item?.keyEquivalentModifierMask == chord.modifiers) }
        }
    }

    @Test func sideTabsAreOptionCommandDigitsInSideTabOrder() {
        let tabs = Shortcut.table.filter { $0.action == #selector(CockpitWindowController.showSideTab(_:)) }
        #expect(tabs.map(\.title) == SideTab.allCases.map(\.title))
        #expect(tabs.map(\.tag) == Array(SideTab.allCases.indices))
        #expect(tabs.map { $0.chord?.key } == (1...SideTab.allCases.count).map { "\($0)" })
        #expect(tabs.allSatisfy { $0.chord?.modifiers == [.command, .option] })
    }

    @Test func projectsAreCommandOneToNine() {
        let projects = Shortcut.table.filter { $0.action == #selector(CockpitWindowController.showProject(_:)) }
        #expect(projects.map { $0.chord?.glyphs } == (1...9).map { "⌘\($0)" })
    }

    @Test func requestedChordsArePresent() {
        let glyphs = Set(chords.map(\.glyphs))
        for expected in ["⌃⇥", "⌃⇧⇥", "⌥⌘←", "⌥⌘→", "⌘J", "⇧⌘J", "⌘\\", "⇧⌘\\", "⌘K", "⌘/", "⌘F", "⌘G", "⇧⌘G", "⌘O", "⇧⌘⏎", "⌘L"] {
            #expect(glyphs.contains(expected), "\(expected) is missing")
        }
    }

    @Test func maestroUpdateAndFilaAreInTheMenus() {
        let update = Shortcut.table.first { $0.action == #selector(CockpitWindowController.updateAllMaestros(_:)) }
        #expect(update?.title == "Atualizar todos os maestros")
        #expect(update?.chord == nil)
        let fila = Shortcut.table.first { $0.action == #selector(CockpitWindowController.addToQueue(_:)) }
        #expect(fila?.chord?.glyphs == "⇧⌘⏎")
    }

    /// The terminal sends ⌘⌫, ⌘⌦, ⌘← and ⌘→ to the shell itself; none of
    /// those may be a menu chord, or one of the two would never fire.
    @Test func noChordIsOneTheTerminalTranslates() {
        let terminalOwned: Set<Shortcut.Chord> = [
            .init(key: Shortcut.leftArrow, modifiers: .command),
            .init(key: Shortcut.rightArrow, modifiers: .command),
            .init(key: "\u{7F}", modifiers: .command),
            .init(key: "\u{F728}", modifiers: .command),
        ]
        #expect(Set(chords).isDisjoint(with: terminalOwned))
    }

    @Test func sheetGroupsRunsAndBalancesColumns() {
        let sections = Shortcut.sheetSections(from: Shortcut.table)
        let rows = sections.flatMap(\.rows)
        #expect(rows.contains(.init(title: "Projeto 1–9", keys: "⌘1–9")))
        #expect(rows.contains(.init(title: "Aba lateral: Palco … Terminal", keys: "⌥⌘1–8")))
        #expect(rows.contains(.init(title: "Atalhos de teclado", keys: "⌘/")))
        // Every item with a chord is on the sheet: grouped ones as one line.
        let keyed = Shortcut.table.filter { $0.chord != nil }
        let groups = Set(keyed.compactMap(\.sheetGroup))
        #expect(rows.count == keyed.filter { $0.sheetGroup == nil }.count + groups.count)
        let (left, right) = Shortcut.sheetColumns(sections)
        #expect(left + right == sections)
        let height = { (column: [Shortcut.SheetSection]) in column.map { $0.rows.count + 1 }.reduce(0, +) }
        #expect(abs(height(left) - height(right)) <= 4)
    }
}

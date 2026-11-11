import AppKit

/// One item of the cockpit's menu bar, with its chord.
///
/// The menu bar and the "Atalhos de teclado" sheet are both built from
/// `Shortcut.table`: one list, so a chord can never be in the menu and missing
/// from the sheet, or the other way round, and a test can see every chord at once.
struct Shortcut {
    /// The menus of the bar, in the order they appear.
    enum Menu: String, CaseIterable {
        case app = "Vitra"
        case file = "Arquivo"
        case edit = "Editar"
        case go = "Ir"
        case view = "Exibir"
        case window = "Janela"
        case help = "Ajuda"
    }

    /// A key and the modifiers held with it.
    struct Chord: Hashable {
        let key: String
        let modifiers: NSEvent.ModifierFlags

        func hash(into hasher: inout Hasher) {
            hasher.combine(key.lowercased())
            hasher.combine(modifiers.rawValue)
        }

        static func == (lhs: Chord, rhs: Chord) -> Bool {
            lhs.key.lowercased() == rhs.key.lowercased() && lhs.modifiers == rhs.modifiers
        }

        /// How the chord is printed: ⌃⌥⇧⌘ in Apple's order, then the key.
        var glyphs: String {
            var text = ""
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.option) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            if modifiers.contains(.command) { text += "⌘" }
            return text + Self.glyph(for: key)
        }

        private static func glyph(for key: String) -> String {
            switch key {
            case "\t", Shortcut.backTab: return "⇥"
            case "\r": return "⏎"
            case Shortcut.leftArrow: return "←"
            case Shortcut.rightArrow: return "→"
            default: return key.uppercased()
            }
        }
    }

    let menu: Menu
    let title: String
    /// Nil for an item reached only with the pointer.
    let chord: Chord?
    let action: Selector
    var tag = 0
    /// A rule above the item, to group it apart from the one before.
    var separatorBefore = false
    /// Items sharing a label are one line of the sheet ("Projeto 1–9").
    var sheetGroup: String?
    /// More chords for the same item: hidden twins in the menu, which still
    /// answer their keys, so an older habit keeps working.
    var alternates: [Chord] = []

    // MARK: - Keys AppKit spells as characters

    static let backTab = "\u{19}"
    static let leftArrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    static let rightArrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

    private static func chord(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> Chord {
        Chord(key: key, modifiers: modifiers)
    }

    // MARK: - The table

    /// Every item of the cockpit's menu bar, in menu order.
    @MainActor static let table: [Shortcut] = {
        var items: [Shortcut] = [
            Shortcut(menu: .app, title: "Sobre o Vitra", chord: nil, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            Shortcut(menu: .app, title: "Atualizar todos os maestros", chord: nil, action: #selector(CockpitWindowController.updateAllMaestros(_:)), separatorBefore: true),
            Shortcut(menu: .app, title: "Ocultar Vitra", chord: chord("h"), action: #selector(NSApplication.hide(_:)), separatorBefore: true),
            Shortcut(menu: .app, title: "Encerrar Vitra (segure)", chord: chord("q"), action: #selector(CockpitAppDelegate.quitRequested(_:)), separatorBefore: true),
            Shortcut(menu: .app, title: "Encerrar todos os terminais e sair", chord: nil, action: #selector(CockpitAppDelegate.endTerminalsAndQuit(_:))),

            Shortcut(menu: .file, title: "Abrir projeto…", chord: chord("o"), action: #selector(CockpitWindowController.openProject(_:))),
            Shortcut(menu: .file, title: "Fechar projeto", chord: chord("w"), action: #selector(CockpitWindowController.closeProject(_:))),
            Shortcut(menu: .file, title: "Adicionar à fila", chord: chord("\r", [.command, .shift]), action: #selector(CockpitWindowController.addToQueue(_:)), separatorBefore: true),

            Shortcut(menu: .edit, title: "Recortar", chord: chord("x"), action: #selector(NSText.cut(_:)), sheetGroup: "Recortar, copiar, colar, tudo"),
            Shortcut(menu: .edit, title: "Copiar", chord: chord("c"), action: #selector(NSText.copy(_:)), sheetGroup: "Recortar, copiar, colar, tudo"),
            Shortcut(menu: .edit, title: "Colar", chord: chord("v"), action: #selector(NSText.paste(_:)), sheetGroup: "Recortar, copiar, colar, tudo"),
            Shortcut(menu: .edit, title: "Selecionar tudo", chord: chord("a"), action: #selector(NSResponder.selectAll(_:)), sheetGroup: "Recortar, copiar, colar, tudo"),
            Shortcut(menu: .edit, title: "Buscar na conversa…", chord: chord("f"), action: #selector(CockpitWindowController.findInConversation(_:)), separatorBefore: true),
            Shortcut(menu: .edit, title: "Próxima ocorrência", chord: chord("g"), action: #selector(CockpitWindowController.findNextInConversation(_:))),
            Shortcut(menu: .edit, title: "Ocorrência anterior", chord: chord("g", [.command, .shift]), action: #selector(CockpitWindowController.findPreviousInConversation(_:))),
            Shortcut(menu: .edit, title: "Limpar o terminal", chord: chord("k"), action: #selector(TerminalView.clearScreen(_:)), separatorBefore: true),

            Shortcut(menu: .go, title: "Próximo projeto", chord: chord("\t", .control), action: #selector(CockpitWindowController.nextProject(_:)),
                     alternates: [chord("]", [.command, .shift])]),
            Shortcut(menu: .go, title: "Projeto anterior", chord: chord(backTab, [.control, .shift]), action: #selector(CockpitWindowController.previousProject(_:)),
                     alternates: [chord("[", [.command, .shift])]),
        ]
        for number in 1...9 {
            items.append(Shortcut(menu: .go, title: "Projeto \(number)", chord: chord("\(number)"), action: #selector(CockpitWindowController.showProject(_:)),
                                  tag: number - 1, separatorBefore: number == 1, sheetGroup: "Projeto 1–9"))
        }
        items += [
            Shortcut(menu: .go, title: "Próxima aba lateral", chord: chord(rightArrow, [.command, .option]), action: #selector(CockpitWindowController.nextSideTab(_:)), separatorBefore: true),
            Shortcut(menu: .go, title: "Aba lateral anterior", chord: chord(leftArrow, [.command, .option]), action: #selector(CockpitWindowController.previousSideTab(_:))),
        ]
        let sideTabs = SideTab.allCases
        for (index, tab) in sideTabs.enumerated() {
            items.append(Shortcut(menu: .go, title: tab.title, chord: chord("\(index + 1)", [.command, .option]), action: #selector(CockpitWindowController.showSideTab(_:)),
                                  tag: index, sheetGroup: "Aba lateral: \(sideTabs.first?.title ?? "") … \(sideTabs.last?.title ?? "")"))
        }
        items += [
            Shortcut(menu: .go, title: "Focar o maestro", chord: chord("j"), action: #selector(CockpitWindowController.focusMaestro(_:)), separatorBefore: true),
            Shortcut(menu: .go, title: "Focar o painel lateral", chord: chord("j", [.command, .shift]), action: #selector(CockpitWindowController.focusSidePanel(_:))),

            Shortcut(menu: .view, title: "Alternar largura do painel", chord: chord("\\"), action: #selector(CockpitWindowController.toggleSideWidth(_:))),
            Shortcut(menu: .view, title: "Ocultar ou mostrar o painel", chord: chord("\\", [.command, .shift]), action: #selector(CockpitWindowController.toggleSidePanel(_:))),

            Shortcut(menu: .window, title: "Minimizar", chord: chord("m"), action: #selector(NSWindow.performMiniaturize(_:))),
            Shortcut(menu: .window, title: "Zoom", chord: nil, action: #selector(NSWindow.performZoom(_:))),

            Shortcut(menu: .help, title: "Atalhos de teclado", chord: chord("/"), action: #selector(CockpitWindowController.showShortcuts(_:))),
        ]
        return items
    }()

    // MARK: - The menu bar

    /// The cockpit's menu bar, every item from `table`.
    @MainActor static func makeMenuBar(from table: [Shortcut] = table) -> NSMenu {
        let bar = NSMenu()
        for menu in Menu.allCases {
            let submenu = NSMenu(title: menu.rawValue)
            for shortcut in table where shortcut.menu == menu {
                if shortcut.separatorBefore, !submenu.items.isEmpty { submenu.addItem(.separator()) }
                submenu.addItem(shortcut.menuItem(chord: shortcut.chord))
                for alternate in shortcut.alternates {
                    let twin = shortcut.menuItem(chord: alternate)
                    twin.isHidden = true
                    submenu.addItem(twin)
                }
            }
            let item = NSMenuItem(title: menu.rawValue, action: nil, keyEquivalent: "")
            item.submenu = submenu
            bar.addItem(item)
            if menu == .window { NSApp?.windowsMenu = submenu }
            if menu == .help { NSApp?.helpMenu = submenu }
        }
        return bar
    }

    private func menuItem(chord: Chord?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: chord?.key ?? "")
        if let chord { item.keyEquivalentModifierMask = chord.modifiers }
        item.tag = tag
        return item
    }

    // MARK: - The sheet

    /// One line of the sheet: what it does and the chord that does it.
    struct SheetRow: Equatable {
        let title: String
        let keys: String
    }

    struct SheetSection: Equatable {
        let title: String
        let rows: [SheetRow]
    }

    /// The sheet's order: where to go first, then what to show, then the rest.
    static let sheetOrder: [Menu] = [.go, .view, .file, .edit, .app, .window, .help]

    /// The sheet's sections: every item that has a chord, grouped items as one
    /// line ("⌘1–9  Projeto 1–9").
    static func sheetSections(from table: [Shortcut]) -> [SheetSection] {
        sheetOrder.compactMap { menu in
            var rows: [SheetRow] = []
            var groups: [String: [Chord]] = [:]
            var order: [String] = []
            for shortcut in table where shortcut.menu == menu {
                guard let chord = shortcut.chord else { continue }
                guard let group = shortcut.sheetGroup else {
                    order.append(shortcut.title)
                    groups[shortcut.title] = [chord]
                    continue
                }
                if groups[group] == nil { order.append(group) }
                groups[group, default: []].append(chord)
            }
            rows = order.map { SheetRow(title: $0, keys: Self.keys(for: groups[$0] ?? [])) }
            return rows.isEmpty ? nil : SheetSection(title: menu.rawValue, rows: rows)
        }
    }

    /// Several chords as one: "⌥⌘1–8" for a run of digits, else side by side.
    static func keys(for chords: [Chord]) -> String {
        guard let first = chords.first, let last = chords.last else { return "" }
        let digits = chords.compactMap { Int($0.key) }
        let isRun = chords.count > 1 && digits.count == chords.count
            && chords.allSatisfy { $0.modifiers == first.modifiers }
            && zip(digits, digits.dropFirst()).allSatisfy { $1 == $0 + 1 }
        if isRun { return first.glyphs + "–" + last.key }
        return chords.map(\.glyphs).joined(separator: " ")
    }

    /// The sections split into two columns of about the same height, without
    /// changing their order.
    static func sheetColumns(_ sections: [SheetSection]) -> (left: [SheetSection], right: [SheetSection]) {
        // A section's height: its rows, and one for its title.
        let heights = sections.map { $0.rows.count + 1 }
        let total = heights.reduce(0, +)
        var best = 0
        var bestDifference = Int.max
        var running = 0
        for split in 0...sections.count {
            let difference = abs(total - 2 * running)
            if difference < bestDifference { (best, bestDifference) = (split, difference) }
            if split < sections.count { running += heights[split] }
        }
        return (Array(sections[..<best]), Array(sections[best...]))
    }
}

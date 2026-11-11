import AppKit
import VitraOrchestrator

/// What the provider cards need beyond the runs: cheap to read, read off the
/// main thread each time the Resumo is shown.
struct ProviderSetup: Sendable {
    let paths: [WorkerCLI: String]
    let lineup: Lineup
    let switches: ProviderSwitches
}

/// Where the provider cards get their data and keep the switches. The app
/// reads the disk and asks the CLIs; the snapshot tool hands in fixtures.
struct ProviderSource {
    typealias Done<T> = @MainActor @Sendable (T) -> Void

    /// The installed CLIs, the lineup and the switches.
    let loadSetup: (@escaping Done<ProviderSetup>) -> Void
    /// Each CLI's model listing, reported CLI by CLI as it comes. `fresh`
    /// asks every CLI again; otherwise the catalogue's cache is used.
    let list: (_ fresh: Bool, _ each: @escaping @MainActor @Sendable (WorkerCLI, [String]?) -> Void) -> Void
    let saveSwitches: (ProviderSwitches) -> Void

    static var disk: ProviderSource { ProviderSource(
        loadSetup: { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let setup = ProviderSetup(
                    paths: Executables.discover().paths, lineup: Lineup.load(), switches: ProviderSwitches.load()
                )
                DispatchQueue.main.async { MainActor.assumeIsolated { done(setup) } }
            }
        },
        list: { fresh, each in
            DispatchQueue.global(qos: .userInitiated).async {
                let executables = Executables.discover()
                func report(_ cli: WorkerCLI, _ lines: [String]?) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { each(cli, lines) } }
                }
                guard fresh else {
                    let listing = ModelCatalog.cachedListing(executables)
                    report(.claude, listing.claude ? [] : nil)
                    report(.opencode, listing.openCode)
                    report(.gemini, listing.gemini)
                    report(.cursor, listing.cursor)
                    return
                }
                // Each CLI takes seconds: asked side by side, each card's
                // spinner stops when its own answer is in.
                let answers = OSAllocatedUnfairLockBox()
                DispatchQueue.concurrentPerform(iterations: WorkerCLI.allCases.count) { index in
                    let cli = WorkerCLI.allCases[index]
                    let lines = ModelCatalog.lines(of: cli, executables)
                    answers.set(cli, lines)
                    report(cli, lines)
                }
                let got = answers.all
                ModelCatalog.remember(ModelCatalog.Listing(
                    claude: executables.paths[.claude] != nil, openCode: got[.opencode] ?? nil,
                    gemini: got[.gemini] ?? nil, cursor: got[.cursor] ?? nil
                ), for: executables)
            }
        },
        saveSwitches: { switches in
            DispatchQueue.global(qos: .utility).async { try? switches.save() }
        }
    ) }
}

/// The listings gathered from several threads at once.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [WorkerCLI: [String]?] = [:]

    func set(_ cli: WorkerCLI, _ lines: [String]?) {
        lock.lock()
        answers[cli] = lines
        lock.unlock()
    }

    var all: [WorkerCLI: [String]?] {
        lock.lock()
        defer { lock.unlock() }
        return answers
    }
}

/// A provider row opened: why it can or cannot work, the command that would
/// fix it, the switch, and the models it offers.
final class ProviderDetailsView: NSStackView {
    var onCopy: ((String) -> Void)?
    /// Types a command into the project's shared terminal.
    var onRun: ((String) -> Void)?
    /// Whether there is a terminal to type into; without one only copy is offered.
    var canRun: (() -> Bool)?
    var onSwitch: ((Bool) -> Void)?
    var onToggleModels: (() -> Void)?

    private let toggle = NSSwitch()

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = CockpitStyle.Space.sm
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(switched)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// - Parameters:
    ///   - refusal: why the switch was just refused, said under it.
    ///   - note: what came of the last command button, such as "copiado".
    func show(_ card: ProviderCard, calendar: Calendar, refusal: String?, modelsOpen: Bool, note: String?) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }

        let status = NSTextField.wrapping(card.statusText(calendar: calendar), font: CockpitStyle.caption, color: Self.colour(card.state))
        add(status)
        if let detail = card.detailText {
            add(NSTextField.wrapping(detail, font: CockpitStyle.meta, color: CockpitStyle.muted))
        }
        if card.models == nil, card.signedIn == nil, card.path != nil {
            add(NSTextField.label("lendo a lista de modelos…", font: CockpitStyle.meta, color: CockpitStyle.muted))
        }
        if card.state == .notInstalled {
            add(NSTextField.wrapping(ProviderBoard.install(card.cli).hint, font: CockpitStyle.caption, color: CockpitStyle.muted))
        }
        if let command = card.command { add(commandRow(command, note: note)) }

        toggle.state = card.isOn ? .on : .off
        toggle.setAccessibilityLabel("Usar \(card.cli.rawValue) como operário")
        let caption = NSTextField.label("usar como operário", font: CockpitStyle.caption, color: CockpitStyle.text)
        let switchRow = NSStackView(views: [toggle, caption])
        switchRow.spacing = CockpitStyle.Space.sm
        switchRow.alignment = .centerY
        add(switchRow, fills: false)
        if let refusal {
            add(NSTextField.wrapping(refusal, font: CockpitStyle.caption, color: CockpitStyle.dangerText))
        }

        if let models = card.models, !models.isEmpty {
            let title = (modelsOpen ? "▾ " : "▸ ") + (models.count == 1 ? "1 modelo oferecido" : "\(models.count) modelos oferecidos")
            let button = ClosureButton(title: title, font: CockpitStyle.caption, color: CockpitStyle.muted) { [weak self] in
                self?.onToggleModels?()
            }
            button.setAccessibilityLabel(title.dropFirst(2) + (modelsOpen ? ", aberta" : ", fechada"))
            add(button, fills: false)
            if modelsOpen { models.forEach { add(modelLine($0, tiers: card.tiers[$0] ?? [])) } }
        }
    }

    /// Adds `view` across the whole width, or at its own width when `fills` is false.
    private func add(_ view: NSView, fills: Bool = true) {
        addArrangedSubview(view)
        if fills {
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -(edgeInsets.left + edgeInsets.right)).isActive = true
        }
    }

    /// `$ cursor-agent login`, with copy and, where it can, run.
    private func commandRow(_ command: String, note: String?) -> NSView {
        let text = NSTextField.label("$ " + command, font: CockpitStyle.meta, color: CockpitStyle.code)
        text.lineBreakMode = .byTruncatingMiddle
        text.toolTip = command
        let plate = NSView.pill([text])
        var views: [NSView] = [plate]
        let copy = ClosureButton(title: "copiar comando", font: CockpitStyle.caption, color: CockpitStyle.accent) { [weak self] in
            self?.onCopy?(command)
        }
        views.append(copy)
        if canRun?() == true {
            views.append(ClosureButton(title: "abrir no terminal", font: CockpitStyle.caption, color: CockpitStyle.accent) { [weak self] in
                self?.onRun?(command)
            })
        }
        let buttons = NSStackView(views: Array(views.dropFirst()))
        buttons.spacing = CockpitStyle.Space.md
        if let note { buttons.addArrangedSubview(NSTextField.label(note, font: CockpitStyle.caption, color: CockpitStyle.muted)) }
        let stack = NSStackView(views: [plate, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CockpitStyle.Space.xs
        plate.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    /// One model, and the lineup tiers it is in.
    private func modelLine(_ offer: ModelCatalog.Offer, tiers: [Difficulty]) -> NSView {
        let name = RankingView.flexible(ProviderBoard.modelName(offer), font: CockpitStyle.meta, color: CockpitStyle.code)
        name.lineBreakMode = .byTruncatingMiddle
        let tags = NSTextField.label(tiers.map(LineupBoard.title).joined(separator: " · "), font: CockpitStyle.micro, color: CockpitStyle.accent)
        tags.setContentCompressionResistancePriority(.required, for: .horizontal)
        tags.setContentHuggingPriority(.required, for: .horizontal)
        let line = RankingView.line([name, tags], height: 18)
        line.setAccessibilityElement(true)
        line.setAccessibilityLabel(tiers.isEmpty ? name.stringValue : "\(name.stringValue), na escalação \(tags.stringValue)")
        return line
    }

    @objc private func switched() { onSwitch?(toggle.state == .on) }

    static func colour(_ state: ProviderState) -> NSColor {
        switch state {
        case .ok: return CockpitStyle.success
        case .noQuota, .resting: return CockpitStyle.accent
        case .down, .signedOut: return CockpitStyle.dangerText
        case .notInstalled: return CockpitStyle.muted
        }
    }
}

/// A borderless text button that runs a closure.
final class ClosureButton: NSButton {
    private let press: () -> Void

    init(title: String, font: NSFont, color: NSColor, press: @escaping () -> Void) {
        self.press = press
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        target = self
        action = #selector(pressed)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func pressed() { press() }
}

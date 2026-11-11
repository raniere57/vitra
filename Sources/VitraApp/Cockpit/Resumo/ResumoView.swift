import AppKit
import VitraOrchestrator

/// The Resumo tab: what the workers cost today and this week, how each
/// provider stands, and a retrospective of the project's last pieces of work.
///
/// Built once and refilled: the provider rows and the twenty trabalho rows are
/// made the first time and reconfigured on every `show`, so a refresh moves no
/// views around and costs the same at 20 runs as at 2,000.
final class ResumoView: NSView {
    private typealias Column = RankingView.Column
    private static let medianWidth: CGFloat = 50

    private let column = NSStackView()
    private let loading = NSTextField.label("Lendo os runs…", font: CockpitStyle.body, color: CockpitStyle.muted)

    // Totals
    private let todayBlock = TotalsBlock(title: "HOJE")
    private let weekBlock = TotalsBlock(title: "7 DIAS")
    private let allProjects = NSTextField.label(font: CockpitStyle.caption, color: CockpitStyle.muted)
    private let sparkline = Sparkline()

    // Providers
    private var providerRows: [WorkerCLI: ProviderRowView] = [:]
    private let providerSource: ProviderSource
    private var providerSetup: ProviderSetup?
    /// What each CLI listed, once it has been asked.
    private var listed: [WorkerCLI: [String]] = [:]
    /// The CLIs being asked for their models right now.
    private var listing: Set<WorkerCLI> = []
    private(set) var openProviders: Set<WorkerCLI> = []
    private var openModels: Set<WorkerCLI> = []
    private var refusal: (cli: WorkerCLI, text: String)?
    private var commandNote: (cli: WorkerCLI, text: String)?
    private lazy var refreshButton = ClosureButton(title: "Atualizar lista", font: CockpitStyle.label, color: CockpitStyle.accent) { [weak self] in
        self?.relist(fresh: true)
    }
    /// Types a command into the project's shared terminal; nil hides the button.
    var onRunCommand: ((String) -> Bool)?

    // Retrospective
    private let copyButton = NSButton(title: "Copiar retrospectiva", target: nil, action: nil)
    private let factsBox = NSStackView()
    private let emptyTrabalhos = NSTextField.wrapping(
        "Ainda não há trabalhos neste projeto. Cada entrega do maestro, com sua auditoria e o que foi refeito, aparece aqui.",
        font: CockpitStyle.body, color: CockpitStyle.muted
    )
    private var trabalhoRows: [TrabalhoRowView] = []

    private var resumo: Resumo?
    /// The trabalho opened, whose steps are shown; nil when none is.
    private(set) var expanded: String?

    init(providers: ProviderSource = .disk) {
        providerSource = providers
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.panel.cgColor
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ resumo: Resumo) {
        self.resumo = resumo
        loading.isHidden = true
        column.isHidden = false
        if let expanded, !resumo.trabalhos.contains(where: { $0.id == expanded }) { self.expanded = nil }

        todayBlock.show(resumo.today)
        weekBlock.show(resumo.week)
        allProjects.stringValue = "todos os projetos · hoje \(WorkerBoard.money(resumo.allToday.cost))"
            + " · 7 dias \(WorkerBoard.money(resumo.allWeek.cost))"
        allProjects.toolTip = "Hoje: \(WorkerBoard.tokens(resumo.allToday.tokens)), \(Resumo.countsText(resumo.allToday))\n"
            + "7 dias: \(WorkerBoard.tokens(resumo.allWeek.tokens)), \(Resumo.countsText(resumo.allWeek))"
        sparkline.show(resumo.days, calendar: resumo.calendar)

        showProviders()
        providerSource.loadSetup { [weak self] setup in
            self?.providerSetup = setup
            self?.showProviders()
        }

        factsBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        factsBox.isHidden = resumo.facts.isEmpty
        if !resumo.facts.isEmpty {
            factsBox.addArrangedSubview(NSTextField.label("O que os números dizem", font: CockpitStyle.title, color: CockpitStyle.text))
            for fact in resumo.facts {
                let line = NSTextField.wrapping("", font: CockpitStyle.body, color: CockpitStyle.code)
                line.attributedStringValue = Self.bullet(fact)
                factsBox.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: factsBox.widthAnchor, constant: -2 * CockpitStyle.Space.lg).isActive = true
            }
        }

        emptyTrabalhos.isHidden = !resumo.trabalhos.isEmpty
        layoutTrabalhos()
    }

    // MARK: - Providers

    /// Opens a provider's card, or closes it. The first card opened asks the
    /// CLIs for their models, from the catalogue's cache when it has them.
    func toggleProvider(_ cli: WorkerCLI) {
        if openProviders.contains(cli) { openProviders.remove(cli) } else { openProviders.insert(cli) }
        if !openProviders.isEmpty, listed.isEmpty, listing.isEmpty { relist(fresh: false) }
        showProviders()
    }

    /// Opens or closes the list of models on a provider's card.
    func toggleModels(_ cli: WorkerCLI) {
        if openModels.contains(cli) { openModels.remove(cli) } else { openModels.insert(cli) }
        showProviders()
    }

    /// Asks the CLIs for their models off the main thread, a spinner on each
    /// row until its answer is in.
    private func relist(fresh: Bool) {
        guard listing.isEmpty else { return }
        listing = providerSetup.map { Set($0.paths.keys) } ?? Set(WorkerCLI.allCases)
        showProviders()
        providerSource.list(fresh) { [weak self] cli, lines in
            guard let self else { return }
            self.listing.remove(cli)
            self.listed[cli] = lines
            self.showProviders()
        }
    }

    private func card(_ row: ProviderRow) -> ProviderCard? {
        guard let setup = providerSetup else { return nil }
        return ProviderBoard.card(
            row.cli, path: setup.paths[row.cli], lines: listed[row.cli], availability: row.availability,
            deliveriesToday: row.deliveries, lineup: setup.lineup, isOn: setup.switches.isOn(row.cli)
        )
    }

    private func showProviders() {
        guard let resumo else { return }
        refreshButton.isEnabled = listing.isEmpty
        for row in resumo.providers {
            providerRows[row.cli]?.show(
                row, subscription: row.cli == .claude ? resumo.subscription : nil, calendar: resumo.calendar,
                card: card(row), state: ProviderRowView.Open(
                    isOpen: openProviders.contains(row.cli), isListing: listing.contains(row.cli),
                    modelsOpen: openModels.contains(row.cli),
                    refusal: refusal?.cli == row.cli ? refusal?.text : nil,
                    note: commandNote?.cli == row.cli ? commandNote?.text : nil
                )
            )
        }
    }

    /// The switch "usar como operário": saved at once, unless it would leave
    /// no installed CLI on.
    private func setProvider(_ cli: WorkerCLI, on: Bool) {
        guard let setup = providerSetup else { return }
        do {
            let switches = try setup.switches.setting(cli, on: on, installed: Set(setup.paths.keys))
            providerSetup = ProviderSetup(paths: setup.paths, lineup: setup.lineup, switches: switches)
            refusal = nil
            providerSource.saveSwitches(switches)
        } catch {
            refusal = (cli, error.text)
        }
        showProviders()
    }

    private func copyCommand(_ cli: WorkerCLI, _ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        say("copiado", for: cli)
    }

    /// A word beside the command's buttons, gone after a moment.
    private func say(_ text: String, for cli: WorkerCLI) {
        commandNote = (cli, text)
        showProviders()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.commandNote?.text == text else { return }
            self.commandNote = nil
            self.showProviders()
        }
    }

    /// Opens a trabalho's steps, or closes them with nil.
    func expand(_ id: String?) {
        expanded = id
        layoutTrabalhos()
    }

    /// What "Copiar retrospectiva" copies: the trabalho opened, else the day.
    var markdown: String? {
        guard let resumo else { return nil }
        if let expanded, let trabalho = resumo.trabalhos.first(where: { $0.id == expanded }) {
            return Retrospective.markdown(trabalho, now: resumo.now)
        }
        return Retrospective.markdown(day: resumo)
    }

    private func layoutTrabalhos() {
        guard let resumo else { return }
        for (index, row) in trabalhoRows.enumerated() {
            guard index < resumo.trabalhos.count else {
                row.isHidden = true
                continue
            }
            let trabalho = resumo.trabalhos[index]
            row.isHidden = false
            row.show(trabalho, isOpen: trabalho.id == expanded, now: resumo.now)
            row.showsSeparator = index < resumo.trabalhos.count - 1
        }
        copyButton.toolTip = expanded == nil
            ? "Copia o resumo do dia em Markdown"
            : "Copia o trabalho aberto em Markdown"
    }

    @objc private func copyRetrospective() {
        guard let text = markdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.title = "Copiado"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copyButton.title = "Copiar retrospectiva" }
    }

    // MARK: - Building

    private func build() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.lg, left: CockpitStyle.inset, bottom: CockpitStyle.Space.xl, right: CockpitStyle.inset)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isHidden = true

        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        addFilling(scroll)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        loading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loading)
        NSLayoutConstraint.activate([
            loading.topAnchor.constraint(equalTo: topAnchor, constant: CockpitStyle.Space.lg),
            loading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CockpitStyle.inset),
        ])

        // Cost: this project's day and week side by side, every project under them.
        let totals = NSStackView(views: [todayBlock, weekBlock])
        totals.distribution = .fillEqually
        totals.spacing = CockpitStyle.Space.xl
        totals.alignment = .top
        add(totals)
        column.setCustomSpacing(CockpitStyle.Space.md, after: totals)
        add(allProjects)
        column.setCustomSpacing(CockpitStyle.Space.xl, after: allProjects)
        let costHeading = heading("CUSTO DOS WORKERS POR DIA")
        add(costHeading)
        column.setCustomSpacing(CockpitStyle.Space.sm, after: costHeading)
        add(sparkline)
        column.setCustomSpacing(CockpitStyle.Space.xxl, after: sparkline)

        // Providers.
        let providersHeading = heading("PROVEDORES · HOJE")
        refreshButton.toolTip = "Pergunta de novo a cada CLI quais modelos ele oferece"
        let providersBar = NSStackView(views: [providersHeading, NSView(), refreshButton])
        providersBar.alignment = .centerY
        add(providersBar)
        column.setCustomSpacing(CockpitStyle.Space.md, after: providersBar)
        add(Self.providerHeader())
        for (index, cli) in WorkerCLI.allCases.enumerated() {
            if index > 0 { add(NSView.rule(CockpitStyle.softLine)) }
            let row = ProviderRowView(cli: cli)
            row.onToggle = { [weak self] in self?.toggleProvider(cli) }
            row.details.onToggleModels = { [weak self] in self?.toggleModels(cli) }
            row.details.onSwitch = { [weak self] on in self?.setProvider(cli, on: on) }
            row.details.onCopy = { [weak self] command in self?.copyCommand(cli, command) }
            row.details.canRun = { [weak self] in self?.onRunCommand != nil }
            row.details.onRun = { [weak self] command in
                guard let self, let run = self.onRunCommand else { return }
                self.say(run(command) ? "enviado ao Terminal" : "o Terminal está ocupado", for: cli)
            }
            providerRows[cli] = row
            add(row)
            if index == WorkerCLI.allCases.count - 1 { column.setCustomSpacing(CockpitStyle.Space.xxl, after: row) }
        }

        // The retrospective.
        copyButton.target = self
        copyButton.action = #selector(copyRetrospective)
        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        copyButton.imagePosition = .imageLeading
        copyButton.contentTintColor = CockpitStyle.accent
        copyButton.font = CockpitStyle.label
        copyButton.attributedTitle = NSAttributedString(string: " Copiar retrospectiva", attributes: [
            .font: CockpitStyle.label, .foregroundColor: CockpitStyle.accent,
        ])
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        let retroHeading = heading("RETROSPECTIVA")
        let retroBar = NSStackView(views: [retroHeading, NSView(), copyButton])
        retroBar.alignment = .centerY
        add(retroBar)
        column.setCustomSpacing(CockpitStyle.Space.lg, after: retroBar)

        factsBox.orientation = .vertical
        factsBox.alignment = .leading
        factsBox.spacing = CockpitStyle.Space.sm
        factsBox.edgeInsets = NSEdgeInsets(top: CockpitStyle.Space.md, left: CockpitStyle.Space.lg, bottom: CockpitStyle.Space.md, right: CockpitStyle.Space.lg)
        factsBox.wantsLayer = true
        factsBox.layer?.backgroundColor = CockpitStyle.raised.cgColor
        factsBox.layer?.cornerRadius = CockpitStyle.Radius.card
        factsBox.layer?.borderWidth = 1
        factsBox.layer?.borderColor = CockpitStyle.raisedLine.cgColor
        add(factsBox)
        column.setCustomSpacing(CockpitStyle.Space.lg, after: factsBox)

        add(emptyTrabalhos)
        for _ in 0..<Resumo.shownTrabalhos {
            let row = TrabalhoRowView()
            row.isHidden = true
            row.onClick = { [weak self, weak row] in
                guard let self, let id = row?.trabalhoID else { return }
                self.expand(self.expanded == id ? nil : id)
            }
            trabalhoRows.append(row)
            add(row)
        }
    }

    private func add(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * CockpitStyle.inset).isActive = true
    }

    private func heading(_ text: String) -> NSTextField {
        NSTextField.label(text, font: CockpitStyle.micro, color: CockpitStyle.text)
    }

    private static func providerHeader() -> NSView {
        let caption = { (text: String, width: CGFloat) in
            RankingView.cell(text, width, .right, font: CockpitStyle.micro, color: CockpitStyle.muted)
        }
        let heads = RankingView.line([
            RankingView.flexible("PROVEDOR", font: CockpitStyle.micro, color: CockpitStyle.muted),
            caption("ENTREGAS", Column.deliveries),
            caption("CUSTO", Column.cost),
            caption("MEDIANA", medianWidth),
        ], height: 20)
        let rule = NSView.rule(CockpitStyle.line)
        let stack = NSStackView(views: [heads, rule])
        stack.orientation = .vertical
        stack.spacing = 0
        heads.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// "•  fact", the lines after the first hanging under the text, not the dot.
    private static func bullet(_ fact: String) -> NSAttributedString {
        let indent: CGFloat = 12
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent
        let text = NSMutableAttributedString(string: "•\t", attributes: [
            .font: CockpitStyle.body, .foregroundColor: CockpitStyle.accent, .paragraphStyle: style,
        ])
        text.append(NSAttributedString(string: fact, attributes: [
            .font: CockpitStyle.body, .foregroundColor: CockpitStyle.code, .paragraphStyle: style,
        ]))
        return text
    }

    static func colour(of cli: WorkerCLI) -> NSColor {
        switch cli {
        case .claude: return CockpitStyle.providerClaude
        case .opencode: return CockpitStyle.providerOpencode
        case .cursor: return CockpitStyle.providerCursor
        case .gemini: return CockpitStyle.providerGemini
        }
    }

    // MARK: - Totals block

    /// "HOJE", the cost large, and tokens and counts under it.
    private final class TotalsBlock: NSStackView {
        private let cost = NSTextField.label(font: CockpitStyle.mono(20, .semibold), color: CockpitStyle.text)
        private let tokens = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)
        private let counts = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.muted)

        init(title: String) {
            super.init(frame: .zero)
            orientation = .vertical
            alignment = .leading
            spacing = CockpitStyle.Space.xs
            let caption = NSTextField.label(title, font: CockpitStyle.micro, color: CockpitStyle.muted)
            for view in [caption, cost, tokens, counts] { addArrangedSubview(view) }
            setCustomSpacing(CockpitStyle.Space.sm, after: cost)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func show(_ totals: SpendTotals) {
            cost.stringValue = WorkerBoard.money(totals.cost)
            tokens.stringValue = WorkerBoard.tokens(totals.tokens)
            counts.stringValue = Resumo.countsText(totals)
            counts.textColor = totals.failures > 0 && totals.failures >= totals.deliveries ? CockpitStyle.dangerText : CockpitStyle.muted
        }
    }
}

// MARK: - A provider

/// One provider: its colour, its name and availability, and today's figures;
/// for claude, the subscription's two windows under it.
private final class ProviderRowView: NSStackView {
    /// How the row is opened, and what its card shows.
    struct Open {
        let isOpen: Bool
        let isListing: Bool
        let modelsOpen: Bool
        let refusal: String?
        let note: String?
    }

    var onToggle: (() -> Void)?
    let details = ProviderDetailsView()
    private let spinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return spinner
    }()
    private let status = NSTextField.label(font: CockpitStyle.caption, color: CockpitStyle.muted)
    private let deliveries = RankingView.cell("", RankingView.Column.deliveries, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let cost = RankingView.cell("", RankingView.Column.cost, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let median = RankingView.cell("", 50, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let week = UsageBar(title: "semana")
    private let fiveHour = UsageBar(title: "5 horas")
    private lazy var bars: NSStackView = {
        // Packed to the left, under the name: the spacer takes the rest.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for bar in [week, fiveHour] { bar.setContentHuggingPriority(.required, for: .horizontal) }
        let stack = NSStackView(views: [week, fiveHour, spacer])
        stack.distribution = .fill
        stack.spacing = CockpitStyle.Space.xl
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.nameIndent, bottom: CockpitStyle.Space.md, right: 0)
        return stack
    }()
    private let cli: WorkerCLI

    /// Where the name starts: past the dot and its gap.
    static let nameIndent: CGFloat = 8 + CockpitStyle.Space.sm

    init(cli: WorkerCLI) {
        self.cli = cli
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        let dot = NSView.filled(ResumoView.colour(of: cli), cornerRadius: 4)
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let name = NSTextField.label(cli.rawValue, font: CockpitStyle.label, color: CockpitStyle.text)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let who = NSStackView(views: [dot, name, status, spinner])
        who.spacing = CockpitStyle.Space.sm
        who.alignment = .centerY
        who.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = RankingView.line([who, deliveries, cost, median], height: CockpitStyle.rowHeight)
        addArrangedSubview(line)
        addArrangedSubview(bars)
        addArrangedSubview(details)
        line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        // Under the name, as the bars are.
        details.edgeInsets = NSEdgeInsets(top: 0, left: Self.nameIndent, bottom: CockpitStyle.Space.lg, right: 0)
        details.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        details.isHidden = true
        bars.isHidden = true
        line.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        line.toolTip = "Clique para ver por que \(cli.rawValue) pode ou não trabalhar"
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clicked() { onToggle?() }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    func show(_ row: ProviderRow, subscription: SubscriptionBars?, calendar: Calendar, card: ProviderCard? = nil, state: Open? = nil) {
        let text = ProviderBoard.rowStatus(row.availability, card: card, calendar: calendar)
        status.stringValue = text
        let byRuns: NSColor = switch row.availability {
        case .ok: CockpitStyle.success
        case .noQuota, .resting: CockpitStyle.accent
        case .down, .signedOut: CockpitStyle.dangerText
        }
        status.textColor = card?.isOn == false ? CockpitStyle.muted : card.map { ProviderDetailsView.colour($0.state) } ?? byRuns
        if state?.isListing == true { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let isOpen = state?.isOpen == true
        details.isHidden = !isOpen || card == nil
        if isOpen, let card, let state {
            details.show(card, calendar: calendar, refusal: state.refusal, modelsOpen: state.modelsOpen, note: state.note)
        }
        setAccessibilityExpanded(isOpen)
        if case let .resting(_, workers) = row.availability {
            status.toolTip = "Em pausa depois de 3 falhas seguidas: " + workers.joined(separator: ", ")
        } else {
            status.toolTip = text
        }
        deliveries.stringValue = "\(row.deliveries)"
        cost.stringValue = WorkerBoard.money(row.cost)
        median.stringValue = row.medianSeconds.map(WorkerBoard.duration) ?? "—"
        bars.isHidden = subscription == nil
        week.show(subscription?.week)
        fiveHour.show(subscription?.fiveHour)
        setAccessibilityLabel("\(cli.rawValue): \(text), \(row.deliveries) entregas hoje, custo \(cost.stringValue), mediana \(median.stringValue)")
    }
}

/// "semana ▬▬▬▭▭ 87 %": a thin bar, amber from 80 % and red from 95 %.
private final class UsageBar: NSStackView {
    private static let width: CGFloat = 64
    private let track = NSView.filled(CockpitStyle.line, cornerRadius: 2)
    private let fill = NSView.filled(CockpitStyle.muted, cornerRadius: 2)
    private let figure = NSTextField.label(font: CockpitStyle.meta, color: CockpitStyle.text)
    private var fillWidth: NSLayoutConstraint?

    init(title: String) {
        super.init(frame: .zero)
        spacing = CockpitStyle.Space.sm
        alignment = .centerY
        let caption = NSTextField.label(title, font: CockpitStyle.caption, color: CockpitStyle.muted)
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: Self.width),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        ])
        for view in [caption, track, figure] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ percent: Double?) {
        isHidden = percent == nil
        guard let percent else { return }
        let clamped = min(max(percent, 0), 100)
        fillWidth?.isActive = false
        fillWidth = fill.widthAnchor.constraint(equalToConstant: Self.width * clamped / 100)
        fillWidth?.isActive = true
        let colour: NSColor = switch SubscriptionBars.level(percent) {
        case .calm: CockpitStyle.muted
        case .warm: CockpitStyle.accent
        case .hot: CockpitStyle.danger
        }
        fill.layer?.backgroundColor = colour.cgColor
        figure.stringValue = "\(Int(percent.rounded())) %"
        figure.textColor = SubscriptionBars.level(percent) == .calm ? CockpitStyle.text : colour
    }
}

// MARK: - The sparkline

/// Seven days of worker cost as a line, each day named under its point and
/// the dearest one labelled with what it cost. Drawn, not a chart library.
private final class Sparkline: NSView {
    private static let height: CGFloat = 72
    private static let top: CGFloat = 18
    private static let bottom: CGFloat = 16
    private var days: [DayCost] = []
    private var calendar = Calendar.current

    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ days: [DayCost], calendar: Calendar) {
        self.days = days
        self.calendar = calendar
        setAccessibilityLabel("Custo dos workers por dia: " + days.map {
            "\(Resumo.weekday($0.day, calendar: calendar)) \(WorkerBoard.money($0.cost))"
        }.joined(separator: ", "))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard days.count > 1 else { return }
        let inset: CGFloat = 12
        let plot = NSRect(x: inset, y: Self.top, width: bounds.width - 2 * inset, height: bounds.height - Self.top - Self.bottom)
        let highest = max(days.map(\.cost).max() ?? 0, 0.01)
        let points = days.enumerated().map { index, day in
            NSPoint(
                x: plot.minX + plot.width * CGFloat(index) / CGFloat(days.count - 1),
                y: plot.maxY - plot.height * CGFloat(day.cost / highest)
            )
        }

        // The baseline, then the area under the line, then the line.
        CockpitStyle.line.setFill()
        NSRect(x: plot.minX, y: plot.maxY, width: plot.width, height: 1).fill()
        let area = NSBezierPath()
        area.move(to: NSPoint(x: points[0].x, y: plot.maxY))
        points.forEach(area.line(to:))
        area.line(to: NSPoint(x: points[points.count - 1].x, y: plot.maxY))
        area.close()
        CockpitStyle.accent.withAlphaComponent(0.10).setFill()
        area.fill()
        let line = NSBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach(line.line(to:))
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        CockpitStyle.accent.setStroke()
        line.stroke()

        let peak = Resumo.peak(days)
        let small: [NSAttributedString.Key: Any] = [.font: CockpitStyle.micro, .foregroundColor: CockpitStyle.muted]
        for (index, point) in points.enumerated() {
            let isPeak = index == peak
            let radius: CGFloat = isPeak ? 3.5 : 2
            (isPeak ? CockpitStyle.accent : CockpitStyle.muted).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)).fill()

            let isToday = index == days.count - 1
            let name = NSAttributedString(string: isToday ? "hoje" : Resumo.weekday(days[index].day, calendar: calendar), attributes: [
                .font: CockpitStyle.micro, .foregroundColor: isToday ? CockpitStyle.text : CockpitStyle.muted,
            ])
            draw(name, centredAt: point.x, y: bounds.height - name.size().height)
            if isPeak {
                let label = NSAttributedString(string: WorkerBoard.money(days[index].cost), attributes: [
                    .font: CockpitStyle.micro, .foregroundColor: CockpitStyle.accent,
                ])
                draw(label, centredAt: point.x, y: point.y - radius - 2 - label.size().height)
            }
        }
        if peak == nil {
            let none = NSAttributedString(string: "nenhum custo nos últimos 7 dias", attributes: small)
            draw(none, centredAt: bounds.midX, y: plot.midY - none.size().height)
        }
    }

    /// Draws `text` centred on `x`, kept inside the view.
    private func draw(_ text: NSAttributedString, centredAt x: CGFloat, y: CGFloat) {
        let width = text.size().width
        let left = min(max(x - width / 2, 0), bounds.width - width)
        text.draw(at: NSPoint(x: left, y: y))
    }
}

// MARK: - A trabalho

/// One trabalho: its title, time and cost, its outcome and chain; opened, each
/// step with who did it, why, what it cost and what came of it.
private final class TrabalhoRowView: NSView {
    var onClick: (() -> Void)?
    private(set) var trabalhoID: String?
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }

    private let title = RankingView.flexible("", font: CockpitStyle.label, color: CockpitStyle.text)
    private let time = RankingView.cell("", RankingView.Column.time, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let cost = RankingView.cell("", RankingView.Column.cost, .right, font: CockpitStyle.meta, color: CockpitStyle.text)
    private let chain = NSTextField.wrapping("", font: CockpitStyle.meta, color: CockpitStyle.muted, lines: 2)
    private let steps = NSStackView()
    private let separator = NSView.rule(CockpitStyle.softLine)
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = CockpitStyle.Radius.control
        title.lineBreakMode = .byTruncatingTail
        let top = RankingView.line([title, time, cost], height: 20)
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = CockpitStyle.Space.md
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CockpitStyle.Space.xs
        for view in [top, chain, steps] as [NSView] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setCustomSpacing(CockpitStyle.Space.md, after: chain)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CockpitStyle.Space.md),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -CockpitStyle.Space.md),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    func show(_ trabalho: Trabalho, isOpen: Bool, now: Date) {
        trabalhoID = trabalho.id
        title.stringValue = trabalho.title
        title.toolTip = trabalho.title
        time.stringValue = WorkerBoard.duration(trabalho.duration(now: now))
        cost.stringValue = WorkerBoard.money(trabalho.cost)

        let outcome = NSMutableAttributedString(string: trabalho.outcomeText, attributes: [
            .font: CockpitStyle.meta, .foregroundColor: Self.colour(trabalho.outcome),
        ])
        outcome.append(NSAttributedString(string: "  " + trabalho.chain, attributes: [
            .font: CockpitStyle.meta, .foregroundColor: CockpitStyle.muted,
        ]))
        chain.attributedStringValue = outcome
        chain.toolTip = trabalho.chain

        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        steps.isHidden = !isOpen
        if isOpen {
            for (index, step) in trabalho.steps.enumerated() {
                let view = Self.stepView(step, place: index + 1, now: now)
                steps.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
            }
        }
        setAccessibilityLabel("\(trabalho.title): \(trabalho.outcomeText), \(time.stringValue), \(cost.stringValue). \(trabalho.chain)")
        setAccessibilityExpanded(isOpen)
    }

    private static func colour(_ outcome: Trabalho.Outcome) -> NSColor {
        switch outcome {
        case .running: return CockpitStyle.accent
        case .delivered: return CockpitStyle.success
        case .failed: return CockpitStyle.dangerText
        case .discarded: return CockpitStyle.muted
        }
    }

    /// A step: place, worker and mark, time and cost; under it why it was
    /// picked, the rating and note, the verdict and what failed.
    private static func stepView(_ step: Trabalho.Step, place: Int, now: Date) -> NSView {
        let head = ([step.roleWord, step.name].compactMap { $0 } + [step.mark]).joined(separator: " ")
        let line = RankingView.line([
            RankingView.cell("\(place)", RankingView.Column.rank, .left, font: CockpitStyle.meta, color: CockpitStyle.muted),
            RankingView.flexible(head, font: CockpitStyle.body, color: CockpitStyle.text),
            RankingView.cell(WorkerBoard.duration((step.run.ended ?? now).timeIntervalSince(step.run.started)),
                             RankingView.Column.time, .right, font: CockpitStyle.meta, color: CockpitStyle.code),
            RankingView.cell(WorkerBoard.money(step.run.output?.costUSD ?? 0),
                             RankingView.Column.cost, .right, font: CockpitStyle.meta, color: CockpitStyle.code),
        ], height: 18)

        var facts: [(String, NSColor)] = []
        if let chooser = WorkerBoard.chooser(step.run) { facts.append((chooser, CockpitStyle.muted)) }
        if let rating = step.run.rating {
            let note = rating.note.map { " — \($0)" } ?? ""
            facts.append(("nota \(rating.score)/5\(note)", rating.isSatisfactory ? CockpitStyle.code : CockpitStyle.dangerText))
        }
        if let verdict = step.verdictLine { facts.append(("veredito: \(verdict)", CockpitStyle.code)) }
        if let failure = step.failure { facts.append(("falha: \(failure)", CockpitStyle.dangerText)) }

        let stack = NSStackView(views: [line])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CockpitStyle.Space.hair
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let indent = RankingView.Column.rank + RankingView.Column.gap
        let notes = NSStackView()
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = CockpitStyle.Space.hair
        notes.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        for (text, colour) in facts {
            let label = NSTextField.wrapping(text, font: CockpitStyle.caption, color: colour, lines: 3)
            notes.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: notes.widthAnchor, constant: -indent).isActive = true
        }
        if !facts.isEmpty {
            stack.addArrangedSubview(notes)
            notes.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let pick = step.run.pick { line.toolTip = pick.text }
        return stack
    }
}

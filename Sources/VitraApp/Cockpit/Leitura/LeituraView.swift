import AppKit

/// Leitura: the maestro's conversation rendered to be read, over the same
/// area as its terminal. The terminal keeps running underneath, untouched;
/// this view only reads the transcript Claude Code writes, and talks back
/// through the same paste-and-Return the Fila uses.
///
/// Nothing runs while it is hidden: the file is not watched, the clock does
/// not tick, no row is laid out.
@MainActor
final class LeituraView: NSView {
    var onBackToTerminal: (() -> Void)?
    /// Sends a message; answers why it could not, or nil once it went.
    var onSend: ((String, @escaping @MainActor (String?) -> Void) -> Void)?
    var onQueue: ((String) -> Void)?
    /// The prompt the maestro's terminal suggests now, if any.
    var suggestionSource: (() -> String?)?
    private var suggestionPoll: Timer?
    private var suggestionChecks = 0
    /// Claude Code writes its suggestion a moment after the turn ends.
    private static let suggestionInterval: TimeInterval = 1.5
    private static let suggestionTries = 12

    /// Looks for a suggestion now and for a while after: none while the
    /// maestro works or Leitura is hidden.
    private func watchSuggestion() {
        suggestionPoll?.invalidate()
        suggestionPoll = nil
        guard isVisible, !isWorking else { return composer.setSuggestion(nil) }
        suggestionChecks = 0
        composer.setSuggestion(suggestionSource?())
        suggestionPoll = Timer.scheduledTimer(withTimeInterval: Self.suggestionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isVisible, !self.isWorking, self.suggestionChecks < Self.suggestionTries else {
                    self.suggestionPoll?.invalidate()
                    self.suggestionPoll = nil
                    return
                }
                self.suggestionChecks += 1
                self.composer.setSuggestion(self.suggestionSource?())
            }
        }
    }
    var onOpenLink: ((URL) -> Void)? {
        didSet { list.context.openLink = onOpenLink }
    }
    var onOpenWorker: ((String) -> Void)? {
        didSet { list.context.openWorker = onOpenWorker }
    }

    let list = LeituraList()
    let composer = LeituraComposer()
    private let banner = PermissionBanner()
    private let empty = LeituraEmptyState()
    private let pill = NewMessagesPill()
    private(set) lazy var find: LeituraFind = {
        let find = LeituraFind(list: list)
        find.onClose = { [weak self] in self?.focusList() }
        return find
    }()

    private let project: CockpitProject
    private let transcripts: URL
    private var reader: TranscriptReader?
    private var session: String?
    private var items: [TranscriptItem] = []
    private var queued: [UserMessage] = []
    private var transcriptTurn: (isOpen: Bool?, started: Date?, lastActivity: Date?) = (nil, nil, nil)
    /// A turn the transcript left open counts as work for this long after
    /// its last line: a maestro killed mid-turn must not "work" forever.
    private static let openTurnGrace: TimeInterval = 20 * 60

    /// Working, by the hooks or — when they missed the turn's start, as they
    /// do for one a background task or a queued prompt began — by the
    /// transcript itself.
    private var isWorking: Bool {
        if attention == .working { return true }
        guard attention != .needsPermission, transcriptTurn.isOpen == true, let last = transcriptTurn.lastActivity else { return false }
        return list.context.now().timeIntervalSince(last) < Self.openTurnGrace
    }
    private var hasOlder = false
    private var isLoadingOlder = false
    private var isMissing = false
    private(set) var isVisible = false
    private var hasLanded = false
    private var attention: AttentionState?
    private var workingSince: Date?
    private var clock: Timer?
    private var composerHeight: NSLayoutConstraint?

    init(project: CockpitProject, transcripts: URL = Maestro.conversationsDirectory) {
        self.project = project
        self.transcripts = transcripts
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ReadingStyle.page.cgColor
        list.context.base = URL(fileURLWithPath: project.path, isDirectory: true)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        for view in [list, composer, banner, empty, pill] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let height = composer.heightAnchor.constraint(equalToConstant: 80)
        composerHeight = height
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: topAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: banner.topAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.bottomAnchor.constraint(equalTo: composer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
            empty.topAnchor.constraint(equalTo: topAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -14),
        ])
        banner.isHidden = true
        banner.onGo = { [weak self] in self?.onBackToTerminal?() }
        empty.isHidden = true
        empty.onBack = { [weak self] in self?.onBackToTerminal?() }
        pill.isHidden = true
        pill.onClick = { [weak self] in
            self?.list.scrollToBottom()
            self?.pill.isHidden = true
        }
        list.onBottomChange = { [weak self] atBottom in if atBottom { self?.pill.isHidden = true } }
        list.onNearTop = { [weak self] in self?.loadOlder() }
        list.context.openImage = { [weak self] image in
            if let url = image.fileURL() { self?.onOpenLink?(url) }
        }
        composer.onOpenAttachment = { [weak self] path in self?.onOpenLink?(URL(fileURLWithPath: path)) }
        composer.onHeightChange = { [weak self] in self?.fitComposer() }
        composer.onEscape = { [weak self] in self?.focusList() }
        composer.onSend = { [weak self] text in
            guard let self else { return }
            self.onSend?(text) { [weak self] problem in
                guard let self else { return }
                if let problem {
                    self.composer.showProblem(problem)
                } else {
                    self.composer.clear()
                    self.list.scrollToBottom()
                }
            }
        }
        composer.onQueue = { [weak self] text in
            self?.onQueue?(text)
            self?.composer.clear()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitComposer()
    }

    private func fitComposer() {
        composerHeight?.constant = composer.preferredHeight(width: max(bounds.width, 200))
    }

    // MARK: - Showing and hiding

    /// Shown: the transcript read (its tail, the first time), followed, and
    /// the clock running if the maestro works. Hidden: all of it stops.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            resolveSession()
            reader?.open()
            reader?.follow(true)
        } else {
            reader?.follow(false)
        }
        updateClock()
        watchSuggestion()
    }

    /// The maestro may be in another conversation now (/resume, /clear,
    /// compaction): a new id is a new file and a fresh read.
    func sessionMayHaveChanged() {
        guard isVisible else { return }
        resolveSession()
        // A transcript that was missing may have been written since.
        if isMissing { reader?.open() }
    }

    private func resolveSession() {
        let current = TranscriptLocator.session(project: project)
        guard current != session || reader == nil else { return }
        session = current
        reader?.follow(false)
        items = []
        queued = []
        hasOlder = false
        hasLanded = false
        guard let current else {
            reader = nil
            showMissing(true)
            return
        }
        let url = TranscriptLocator.url(project: project.path, session: current, root: transcripts)
        reader = TranscriptReader(url: url) { [weak self] update in self?.apply(update) }
        if isVisible {
            reader?.open()
            reader?.follow(true)
        }
    }

    private func apply(_ update: TranscriptReader.Update) {
        isLoadingOlder = false
        hasOlder = update.hasOlder
        showMissing(update.isMissing && update.items.isEmpty)
        items = update.items
        queued = update.queued
        transcriptTurn = (update.isTurnOpen, update.turnStarted, update.lastActivity)
        composer.setWorking(isWorking)
        updateClock()
        refresh()
    }

    /// Items, the live row and the find, from what is known now.
    private func refresh() {
        let addedBelow = list.show(rows())
        if addedBelow { pill.isHidden = false }
        if !hasLanded, !items.isEmpty {
            hasLanded = true
            list.scrollToBottom()
        }
        find.itemsChanged()
    }

    private func rows() -> [LeituraRow] {
        var rows = items.map(LeituraRow.item)
        if isWorking, let since = workingSince ?? transcriptTurn.started ?? transcriptTurn.lastActivity {
            var current: String?
            if case let .activity(activity)? = items.last { current = activity.running?.summary }
            rows.append(.live(LiveState(since: since, current: current)))
        }
        // What waits for the maestro comes last: it is read after the turn.
        return rows + queued.map { .item(.user($0)) }
    }

    private func loadOlder() {
        guard hasOlder, !isLoadingOlder else { return }
        isLoadingOlder = true
        reader?.loadOlder()
    }

    private func showMissing(_ missing: Bool) {
        isMissing = missing
        empty.isHidden = !missing
        list.isHidden = missing
        composer.isHidden = missing
    }

    // MARK: - The maestro's state

    func attention(_ state: AttentionState?, since: Date?) {
        attention = state
        workingSince = state == .working ? (since ?? Date()) : nil
        composer.setWorking(isWorking)
        banner.isHidden = state != .needsPermission
        updateClock()
        watchSuggestion()
        refresh()
    }

    private func updateClock() {
        let runs = isVisible && isWorking
        guard runs != (clock != nil) else { return }
        clock?.invalidate()
        clock = nil
        guard runs else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.list.tickLiveRow() }
        }
    }

    // MARK: - Keyboard

    func focusComposer() { window?.makeFirstResponder(composer.text) }
    func focusList() { window?.makeFirstResponder(list.table) }

    /// A passage of the conversation, set over what is being written as
    /// the thing the reply is about.
    func quote(_ passage: String) {
        composer.addQuote(passage)
        focusComposer()
    }

    /// Markdown's block quote: each line of the passage behind "> ".
    static func quoted(_ passage: String) -> String {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    func showFind() { find.open(in: self) }

    func findStep(forward: Bool) {
        guard find.isOpen else { return showFind() }
        find.step(forward: forward)
    }

    // MARK: - For the snapshot tool

    /// Shows `items` as if read from a transcript, with no file and no reader.
    func showForSnapshot(_ items: [TranscriptItem], queued: [UserMessage] = [], attention state: AttentionState?, since: Date?, missing: Bool = false) {
        self.items = items
        self.queued = queued
        isVisible = true
        showMissing(missing)
        attention = state
        workingSince = since
        composer.setWorking(state == .working)
        banner.isHidden = state != .needsPermission
        hasLanded = true
        list.show(rows())
    }
}

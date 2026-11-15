import AppKit
import VitraCore
import VitraGhostty

/// A place for conversations outside every project: plain claude, in a
/// folder of its own. It is kept like any other: after a relaunch the last
/// one comes back where it stopped (`/clear` starts a new one).
final class ScratchChatView: NSView {
    /// Where the conversation runs, and so where claude files it.
    static var folder: URL { Vitra.supportDirectory.appendingPathComponent("avulsa") }

    /// Whether claude has a conversation filed for the folder already.
    static func hasConversation(conversations: URL = Maestro.conversationsDirectory) -> Bool {
        let slugs = Set([folder.path, folder.resolvingSymlinksInPath().path].map(TranscriptLocator.slug(for:)))
        return slugs.contains { slug in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: conversations.appendingPathComponent(slug).path)) ?? []
            return files.contains { $0.hasSuffix(".jsonl") }
        }
    }

    private let kit: TerminalKit
    private var terminal: TerminalView?

    init(kit: TerminalKit) {
        self.kit = kit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CockpitStyle.ground.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Starts claude the first time it is shown; after that the same
    /// conversation is there until Vitra quits.
    func show() {
        if terminal == nil { start() }
        if let terminal { window?.makeFirstResponder(terminal) }
    }

    private func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let size = TerminalSize(columns: 80, rows: 24)
        let shell = kit.config.shell ?? ShellEnvironment.loginShell()
        // No VITRA_PANE or project: this is not a maestro, and the cockpit's
        // hooks and tools have nothing to do with it.
        let environment = ShellEnvironment.childEnvironment(
            shell: shell,
            shellIntegration: kit.config.shellIntegration,
            blockSpacing: kit.config.blockSpacing,
            colorPrompt: kit.config.colorPrompt,
            colorDefaults: kit.config.colorDefaults,
            extra: [:]
        )
        guard let core = try? GhosttyTerminalCore(size: size),
              let session = try? TerminalSession(
                  core: core, executable: shell, arguments: ["-l"], environment: environment,
                  size: size, workingDirectory: Self.folder.path
              ),
              let view = try? TerminalView(session: session, device: kit.device, fontName: kit.config.fontName, fontSize: CGFloat(kit.config.fontSize))
        else { return }
        try? view.apply(kit.config)
        view.offersClose = false
        view.focusTint = CockpitStyle.accent
        view.quietsToolBlocks = true
        session.start()
        // The last conversation back, when there is one to go back to.
        session.send(text: Self.hasConversation() ? "claude --continue\n" : "claude\n")
        addFilling(view, inset: CockpitStyle.Space.md)
        terminal = view
    }
}

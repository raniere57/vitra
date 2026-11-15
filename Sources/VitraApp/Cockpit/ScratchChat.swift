import AppKit
import VitraCore
import VitraGhostty

/// A place for one-off conversations: plain claude, in a folder of its own,
/// with nothing kept once Vitra closes.
///
/// claude's `--no-session-persistence` works only with `--print`, one
/// question and one answer. So the conversation here is an ordinary one, and
/// what claude writes of it is wiped when Vitra starts and when it quits:
/// open while Vitra is open, clean the next time.
final class ScratchChatView: NSView {
    /// Where the conversation runs, and so where claude files it.
    static var folder: URL { Vitra.supportDirectory.appendingPathComponent("avulsa") }

    /// Deletes what claude kept of the one-off conversations.
    static func wipe(conversations: URL = Maestro.conversationsDirectory) {
        let slug = TranscriptLocator.slug(for: folder.resolvingSymlinksInPath().path)
        try? FileManager.default.removeItem(at: conversations.appendingPathComponent(slug))
        let plain = TranscriptLocator.slug(for: folder.path)
        if plain != slug { try? FileManager.default.removeItem(at: conversations.appendingPathComponent(plain)) }
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
        session.send(text: "claude\n")
        addFilling(view, inset: CockpitStyle.Space.md)
        terminal = view
    }
}

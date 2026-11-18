import AppKit
import VitraBridge
import VitraOrchestrator

/// A question about the conversation that never enters it: claude's "/btw",
/// which only its terminal can show. A copy of the conversation is asked,
/// with no tools, and nothing of it is kept.
enum SideQuestion {
    static let brief = """
    This is a quick side question about the conversation so far. Answer it directly and briefly from what you \
    already know; you have no tools. It is not part of the task: do not continue the work.
    """

    static func arguments(question: String, session: String) -> [String] {
        [
            "-p", question, "--resume", session, "--fork-session", "--no-session-persistence",
            "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--append-system-prompt", brief,
        ]
    }

    /// The folder the conversation runs in, from the end of its file: claude
    /// finds a conversation by the folder it is asked from.
    static func folder(of transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 256 * 1024 ? size - 256 * 1024 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let match = folderPattern.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
              let path = Range(match.range(at: 1), in: tail)
        else { return nil }
        return String(tail[path])
    }

    private static let folderPattern = try! NSRegularExpression(pattern: #""cwd":"([^"\\]+)""#)

    /// Asks, and answers on the main queue: the answer, or why there is none.
    /// The process returned is the one to end if the user gives up.
    // ponytail: claude is started with the app's environment, not the user's
    // shell; a CLAUDE_CONFIG_DIR set only in a shell profile is not seen.
    @MainActor
    static func ask(_ question: String, session: String, folder: String, done: @escaping @MainActor (Result<String, ToolError>) -> Void) -> Process? {
        guard let claude = Executables.discover().paths[.claude] else {
            done(.failure(ToolError("o claude não foi encontrado")))
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments(question: question, session: session)
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Executables.defaultSearchPath
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Started here, not on the queue below: ending a process that has
        // not started yet raises, and Esc can come at once.
        do { try process.run() } catch {
            done(.failure(ToolError(error.localizedDescription)))
            return nil
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if process.terminationStatus == 0, !text.isEmpty {
                    done(.success(text))
                } else {
                    let why = (text.isEmpty ? problem : text).trimmingCharacters(in: .whitespacesAndNewlines)
                    done(.failure(ToolError(why.isEmpty ? "o claude não respondeu" : String(why.suffix(300)))))
                }
            }
        }
        return process
    }
}

/// The little window of a side question: asked with Return, gone with Esc.
final class SideQuestionPopover: NSViewController, NSPopoverDelegate, NSTextFieldDelegate {
    private let session: String
    private let folder: String
    private let popover = NSPopover()
    private let question = NSTextField()
    private let note = NSTextField.label("Pergunta sobre a conversa, sem entrar nela. ⏎ pergunta · esc fecha", font: CockpitStyle.caption, color: ReadingStyle.faint)
    private let answer = NSTextView()
    private let scroll = NSScrollView()
    private var process: Process?
    private var height: NSLayoutConstraint?
    private static let width: CGFloat = 460
    private static let pad: CGFloat = 16
    private static let tallest: CGFloat = 360
    /// Kept alive while shown: nothing else holds a popover.
    private static var shown: SideQuestionPopover?

    static func show(session: String, folder: String, from view: NSView) {
        shown?.popover.close()
        let asked = SideQuestionPopover(session: session, folder: folder)
        shown = asked
        asked.popover.contentViewController = asked
        asked.popover.behavior = .transient
        // The page's colours are dark whatever the system is set to.
        asked.popover.appearance = NSAppearance(named: .darkAqua)
        asked.popover.delegate = asked
        asked.popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        asked.view.window?.makeFirstResponder(asked.question)
    }

    private init(session: String, folder: String) {
        self.session = session
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let box = EscapeView()
        box.onEscape = { [weak self] in self?.popover.close() }
        question.placeholderString = "Pergunta rápida…"
        question.font = ReadingStyle.body
        question.isBordered = false
        question.drawsBackground = false
        question.focusRingType = .none
        question.textColor = ReadingStyle.text
        question.delegate = self
        question.setAccessibilityLabel("Pergunta rápida sobre a conversa")
        answer.isEditable = false
        answer.drawsBackground = false
        answer.textContainerInset = .zero
        answer.textContainer?.lineFragmentPadding = 0
        answer.textContainer?.widthTracksTextView = true
        answer.isVerticallyResizable = true
        answer.frame = NSRect(x: 0, y: 0, width: Self.width - 2 * Self.pad, height: 0)
        scroll.documentView = answer
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.isHidden = true
        answer.autoresizingMask = [.width]
        let stack = NSStackView(views: [question, note, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CockpitStyle.Space.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        self.height = height
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Self.pad),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Self.pad),
            question.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            height,
        ])
        view = box
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            ask()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover.close()
            return true
        default:
            return false
        }
    }

    private func ask() {
        let words = question.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if process?.isRunning == true { process?.terminate() }
        note.stringValue = "Pensando…"
        note.textColor = ReadingStyle.faint
        process = SideQuestion.ask(words, session: session, folder: folder) { [weak self] result in
            guard let self, self.popover.isShown, self.question.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == words else { return }
            switch result {
            case let .success(text):
                self.note.stringValue = "esc fecha · ⏎ pergunta de novo"
                self.show(text)
            case let .failure(error):
                self.note.stringValue = "Não deu: \(error.message)"
                self.note.textColor = CockpitStyle.dangerText
            }
        }
    }

    private func show(_ text: String) {
        let base: [NSAttributedString.Key: Any] = [.font: ReadingStyle.body, .foregroundColor: ReadingStyle.text]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let shown = NSMutableAttributedString(string: text, attributes: base)
        if let parsed = try? AttributedString(markdown: text, options: options) {
            shown.setAttributedString(NSAttributedString(parsed))
            let all = NSRange(location: 0, length: shown.length)
            // Bold and code keep their trait; everything gets the page's face and colour.
            shown.enumerateAttribute(.inlinePresentationIntent, in: all) { value, range, _ in
                let intent = (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
                var font = ReadingStyle.body
                if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: ReadingStyle.bodySize, weight: .regular) }
                else if intent.contains(.stronglyEmphasized) { font = NSFont.systemFont(ofSize: ReadingStyle.bodySize, weight: .semibold) }
                shown.addAttributes([.font: font, .foregroundColor: ReadingStyle.text], range: range)
            }
        }
        answer.textStorage?.setAttributedString(shown)
        scroll.isHidden = false
        guard let container = answer.textContainer, let layout = answer.layoutManager else { return }
        layout.ensureLayout(for: container)
        height?.constant = min(ceil(layout.usedRect(for: container).height) + 2, Self.tallest)
    }

    func popoverDidClose(_ notification: Notification) {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        if Self.shown === self { Self.shown = nil }
    }
}

/// Esc anywhere in it, not only in its field.
private final class EscapeView: NSView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

import AppKit
import VitraCore
import QuartzCore

/// Terminal · Leitura: the maestro's pane as the terminal it is, or as its
/// conversation rendered to be read. Leitura lies over the terminal's area;
/// the terminal keeps running under it, only not drawn.
extension ProjectView {
    func makeLeitura() -> LeituraView {
        let view = LeituraView(project: project)
        view.onBackToTerminal = { [weak self] in self?.setReading(false) }
        view.onSend = { [weak self] text, done in
            guard let self else { return done("O projeto foi fechado.") }
            self.sendFromLeitura(text, done: done)
        }
        view.onQueue = { [weak self] text in self?.enqueue(text) }
        // Claude Code's own "send queued messages now": ⌃X ⌃S, the chord that
        // every terminal passes on (⌃⏎ reaches some as a plain Return).
        view.onDeliverQueue = { [weak self] in self?.deliverQueueNow() }
        view.suggestionSource = { [weak self] in self?.terminal?.suggestedInput() }
        view.menuSource = { [weak self] in self?.terminal?.askedMenu() }
        view.onMenuKeys = { [weak self] keys in self?.terminal?.session.send(text: keys) }
        view.onMenuAnswer = { [weak self] option, text in self?.answerMenu(option, with: text) }
        view.onOpenLink = { [weak self] url in self?.openTerminalLink(url, external: false) }
        view.onOpenWorker = { [weak self] id in
            self?.choose(.workers)
            self?.workers.reveal(id)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        // Over the terminal's slot as a sibling, not inside it: a shell that
        // restarts puts a new terminal in the slot, and must not land on top.
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: terminalArea.topAnchor),
            view.leadingAnchor.constraint(equalTo: terminalArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalArea.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor),
        ])
        return view
    }

    func makeReadingSwitch() -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Terminal", "Leitura"], trackingMode: .selectOne, target: self, action: #selector(readingChosen(_:)))
        control.controlSize = .small
        control.font = CockpitStyle.meta
        control.selectedSegment = isReading ? 1 : 0
        control.toolTip = "Terminal ou Leitura: a conversa do maestro renderizada para ler (⌘L)"
        control.setToolTip("O terminal do maestro", forSegment: 0)
        control.setToolTip("A conversa renderizada para ler", forSegment: 1)
        return control
    }

    func measureReadingSwitch() -> (full: CGFloat, compact: CGFloat) {
        showReadingSwitch(compact: true)
        let compact = readingSwitch.fittingSize.width
        showReadingSwitch(compact: false)
        return (readingSwitch.fittingSize.width, compact)
    }

    /// Words, or two icons when the header is tight.
    func showReadingSwitch(compact: Bool) {
        let looks: [(label: String, symbol: String)] = [("Terminal", "terminal"), ("Leitura", "text.alignleft")]
        for (segment, look) in looks.enumerated() {
            if compact {
                readingSwitch.setLabel("", forSegment: segment)
                readingSwitch.setImage(NSImage(systemSymbolName: look.symbol, accessibilityDescription: look.label), forSegment: segment)
                readingSwitch.setWidth(30, forSegment: segment)
            } else {
                readingSwitch.setImage(nil, forSegment: segment)
                readingSwitch.setLabel(look.label, forSegment: segment)
                readingSwitch.setWidth(0, forSegment: segment)
            }
        }
    }

    @objc private func readingChosen(_ sender: NSSegmentedControl) {
        setReading(sender.selectedSegment == 1)
    }

    /// ⌘L.
    func toggleReading() {
        // Leitura renders what Claude Code writes down; another CLI has none.
        guard project.maestro.hasReading else { return NSSound.beep() }
        setReading(!isReading)
    }

    /// Switches the pane, and hands the keyboard to what is now in front:
    /// the composer in Leitura, the terminal back in Terminal.
    func setReading(_ reading: Bool) {
        guard reading != isReading else {
            readingSwitch.selectedSegment = reading ? 1 : 0
            return
        }
        isReading = reading
        applyReading()
        onReadingChange?(reading)
        if reading {
            leitura.focusComposer()
        } else if let terminal {
            window?.makeFirstResponder(terminal)
        }
    }

    func applyReading() {
        readingSwitch.selectedSegment = isReading ? 1 : 0
        let shown = window != nil
        terminal?.setDrawingActive(!isReading && shown)
        if isReading {
            let record = Attention.load(for: project.key)
            leitura.attention(record?.state, since: record?.since)
            leitura.isHidden = false
            leitura.setVisible(shown)
        } else if leitura.superview != nil || isLeituraMade {
            leitura.isHidden = true
            leitura.setVisible(false)
        }
        pulseSwitch(isReading && Attention.load(for: project.key)?.state == .needsPermission)
        // The panel takes the room the reading column does not use.
        needsLayout = true
    }

    /// Whether Leitura was ever made; asking `leitura` itself would make it.
    var isLeituraMade: Bool { subviews.contains { $0 is LeituraView } }

    /// The maestro's state, for Leitura's live row, composer and banner.
    func leituraAttentionChanged(to state: AttentionState?) {
        guard isLeituraMade else { return }
        let record = Attention.load(for: project.key)
        leitura.attention(state, since: record?.state == state ? record?.since : nil)
        pulseSwitch(isReading && state == .needsPermission)
    }

    // MARK: - Talking from Leitura

    /// The composer's message into the maestro's prompt, the way the Fila
    /// sends: pasted whole, then Return. Nil once it went; else why not.
    func sendFromLeitura(_ text: String, done: @escaping @MainActor (String?) -> Void) {
        guard let terminal, terminal.session.isRunningProgram else {
            return done("O maestro não está rodando no terminal. Volte ao terminal para iniciá-lo.")
        }
        // What may sit half-typed in the terminal's prompt cannot be seen from
        // here, and pasted onto it the message would be a third one: the
        // prompt is emptied first (⌃U, a line at a time). Not checked by
        // reading the screen back — Claude Code's suggested next prompt reads
        // as typed text there, and a send must not be refused over a guess.
        let session = terminal.session
        session.send(text: String(repeating: "\u{15}", count: Self.clears))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearDelay) { [weak self] in
            self?.submit(text, to: session)
        }
        done(nil)
    }

    /// The user's own words into a question's "Type something": its digit
    /// puts the cursor in the field, the words are typed there, Return sends.
    func answerMenu(_ option: TerminalMenu.Option, with text: String) {
        guard let session = terminal?.session else { return }
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        session.send(text: String(option.number))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            session.send(text: words)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { session.send(text: "\r") }
        }
    }

    /// ⌃U on an empty prompt does nothing: a few more than any prompt has lines.
    private static let clears = 8
    private static let clearDelay: TimeInterval = 0.12

    /// Claude Code's "send queued messages now": ⌃⏎, as the key itself and
    /// not as bytes — the terminal encodes it the way the program asked to
    /// be told (Kitty protocol, modifyOtherKeys), which raw control bytes do
    /// not survive. Then ⌃X ⌃S, its other binding, for a terminal state in
    /// which ⌃⏎ is only a Return; with nothing left in the queue it does nothing.
    func deliverQueueNow() {
        guard let session = terminal?.session else { return }
        session.send(KeyEvent(keyCode: Self.returnKey, modifiers: .control, text: "\r", unshiftedCodepoint: 13))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            session.send(KeyEvent(keyCode: Self.xKey, modifiers: .control, text: "\u{18}", unshiftedCodepoint: 120))
            session.send(KeyEvent(keyCode: Self.sKey, modifiers: .control, text: "\u{13}", unshiftedCodepoint: 115))
        }
    }

    private static let returnKey: UInt16 = 36
    private static let xKey: UInt16 = 7
    private static let sKey: UInt16 = 1

    // MARK: - The switch calls for attention

    /// While Leitura is shown and the maestro waits on a terminal prompt, a
    /// slow amber ring breathes around the switch; still under Reduce Motion.
    func pulseSwitch(_ on: Bool) {
        readingSwitch.wantsLayer = true
        guard let layer = readingSwitch.layer else { return }
        layer.sublayers?.filter { $0.name == "pulse" }.forEach { $0.removeFromSuperlayer() }
        guard on else { return }
        let ring = CALayer()
        ring.name = "pulse"
        ring.frame = layer.bounds.insetBy(dx: -1, dy: -1)
        // The switch narrows to icons after this is drawn; the ring follows.
        ring.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        ring.cornerRadius = 7
        ring.borderWidth = 1.5
        ring.borderColor = CockpitStyle.accent.cgColor
        layer.masksToBounds = false
        layer.addSublayer(ring)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.2
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        ring.add(pulse, forKey: "pulse")
    }
}

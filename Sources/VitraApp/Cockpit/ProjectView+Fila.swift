import AppKit
import os
import VitraCore

/// The Fila: prompts lined up for the maestro, sent one per finished turn.
///
/// The moment is the Stop hook — the window sees the maestro's attention
/// state go from working to waiting — and the decision is `QueueDispatch`'s.
/// A prompt goes in as a paste, the way pasted text does, so a multi-line one
/// arrives whole; Return follows a moment later.
extension ProjectView {
    private static let log = Logger(subsystem: "dev.vitra", category: "fila")

    func buildQueueDrawer() {
        queueDrawer.show(promptQueue)
        queueDrawer.onChange = { [weak self] queue in self?.queueEdited(queue) }
        queueDrawer.onResume = { [weak self] in
            guard let self else { return }
            self.offerQueue(.resumed(state: Attention.load(for: self.project.path)?.state))
        }
        queueDrawer.onDismiss = { [weak self] in
            self?.queueDrawer.collapse()
            self?.focusTerminal()
        }
    }

    /// ⇧⌘⏎ and "Adicionar à fila": the list open, the keyboard in its field.
    func openQueue() {
        queueDrawer.open(focusingField: true)
    }

    private func queueEdited(_ queue: PromptQueue) {
        promptQueue = queue
        saveQueue()
        onQueueChange?()
    }

    private func saveQueue() {
        guard let queueStore else { return }
        do {
            try PromptQueueStore.save(promptQueue, for: project.path, in: queueStore)
        } catch {
            // The queue still works for this launch; it is just not kept.
            Self.log.error("could not save the queue of \(self.project.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends the head of the queue if `moment` is one to send at. Held back
    /// by text in the maestro's input, it is looked at again every few
    /// seconds for as long as the maestro waits.
    func offerQueue(_ moment: QueueDispatch.Moment) {
        queueRetry?.invalidate()
        queueRetry = nil
        guard let terminal else { return }
        let decision = QueueDispatch.decide(
            moment,
            isPaused: promptQueue.isPaused,
            isEmpty: promptQueue.isEmpty,
            typedInput: terminal.typedInput()
        )
        switch decision {
        case .none:
            return
        case .holdForInput:
            queueRetry = Timer.scheduledTimer(withTimeInterval: Self.queueRetryInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.offerQueue(.retry(state: Attention.load(for: self.project.path)?.state))
                }
            }
        case .send:
            sendHead(to: terminal)
        }
    }

    /// The first prompt into the maestro's input, then Return. Taken off the
    /// queue only once it has gone: with no program to take it, it stays.
    private func sendHead(to terminal: TerminalView) {
        guard let prompt = promptQueue.first, terminal.session.isRunningProgram else { return }
        submit(prompt.text, to: terminal.session)
        promptQueue.remove(prompt.id)
        saveQueue()
        queueDrawer.show(promptQueue)
        queueDrawer.showSent(prompt)
        onQueueChange?()
    }

    /// `text` into the maestro's input as a paste — a multi-line message
    /// arrives whole — and Return a moment later. The one way anything is
    /// typed to the maestro on the user's behalf: the Fila and Leitura's
    /// composer both go through it.
    func submit(_ text: String, to session: TerminalSession) {
        session.paste(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.submitDelay) {
            session.send(text: "\r")
        }
    }

    /// Leitura's "pôr na Fila": the message at the end of the queue, sent
    /// when a turn ends like any other.
    func enqueue(_ text: String) {
        guard promptQueue.add(text, now: Date()) != nil else { return }
        queueEdited(promptQueue)
        queueDrawer.show(promptQueue)
    }

    /// The queue as given, for the snapshot tool: never saved.
    func showQueue(_ queue: PromptQueue, expanded: Bool, editing: UUID? = nil) {
        promptQueue = queue
        queueDrawer.show(queue)
        if expanded { queueDrawer.open(focusingField: false) }
        if let editing { queueDrawer.beginEditing(editing) }
    }
}

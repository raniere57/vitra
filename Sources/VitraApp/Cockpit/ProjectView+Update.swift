import AppKit

/// Bringing a maestro that survived a reinstall up to the new build.
///
/// The maestro lives in the pty-host, so quitting and reinstalling Vitra
/// leaves it running the old brief, the old MCP helper and the old hooks.
/// The only way to the new ones is a fresh launch in the same conversation,
/// which is what switching modes already does: `relaunchMaestro()` ends the
/// shell in the host and the exit starts a new one with the maestro in it.
extension ProjectView {
    /// The maestro just attached to was left running by an earlier app:
    /// compared with this build by the stamp its launch left.
    func checkSurvivorBuild() {
        let outdated = MaestroStamp.isOutdated(
            attached: true,
            recorded: MaestroStamp.load(for: project.key),
            current: MaestroStamp.currentBuild()
        )
        guard outdated else { return }
        updateState.markOutdated()
        fitHeader()
    }

    /// This build typed the launch line: the stamp says so, nothing is old.
    func maestroLaunched() {
        if let build = MaestroStamp.currentBuild() {
            MaestroStamp.record(build: build, mode: mode, for: project.key)
        }
        updateState.relaunched()
        fitHeader()
    }

    /// Whether the maestro runs an older build and has not been armed yet.
    var isOutdated: Bool { updateState.phase == .outdated }

    /// "Atualizar". A maestro waiting on the user is restarted at once. One
    /// mid-turn is asked about when `asking`, or else restarted when the
    /// turn ends — what "Atualizar todos os maestros" does for each.
    func updateMaestro(asking: Bool) {
        guard updateState.phase == .outdated else { return }
        // Read now, not from what the window last saw: at launch it may not
        // have seen anything yet.
        let state = Attention.load(for: project.key)?.state
        if state == nil || state == .waiting {
            relaunch(prompt: nil)
            return
        }
        guard asking, let window, window.attachedSheet == nil else {
            armUpdate()
            return
        }
        let alert = NSAlert()
        alert.messageText = "O maestro está no meio de um turno."
        alert.informativeText = "Atualizar agora interrompe o turno: o maestro volta na versão nova, na mesma conversa, e continua de onde parou."
        alert.addButton(withTitle: "Atualizar quando terminar")
        alert.addButton(withTitle: "Atualizar agora")
        let cancel = alert.addButton(withTitle: "Cancelar")
        cancel.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.armUpdate()
            case .alertSecondButtonReturn: self.relaunch(prompt: Maestro.resumePrompt(mode: self.mode))
            default: break
            }
        }
    }

    func armUpdate() {
        updateState.arm()
        fitHeader()
    }

    func cancelArmedUpdate() {
        updateState.cancel()
        fitHeader()
    }

    /// The window saw the maestro's attention state change. An armed update
    /// goes first, on the turn's end; the Fila then waits for the new
    /// maestro's own first turn to end.
    func attentionChanged(from previous: AttentionState?, to state: AttentionState?) {
        if updateState.fires(from: previous, to: state) {
            relaunch(prompt: Maestro.updatedPrompt)
            return
        }
        offerQueue(.transition(from: previous, to: state))
        leituraAttentionChanged(to: state)
    }

    /// Ends the maestro and starts it again in the same conversation, told
    /// `prompt` first when there is one.
    private func relaunch(prompt: String?) {
        nextLaunchPrompt = prompt
        relaunchMaestro()
    }

    /// The pill in each of its looks, for the snapshot tool.
    func showUpdate(_ phase: MaestroUpdateState.Phase) {
        updateState = MaestroUpdateState()
        if phase != .current { updateState.markOutdated() }
        if phase == .armed { updateState.arm() }
        fitHeader()
    }
}

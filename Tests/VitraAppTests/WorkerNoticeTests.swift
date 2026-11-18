import Foundation
import Testing
@testable import VitraApp
@testable import VitraOrchestrator

private func run(_ id: String, label: String? = nil, state: Run.State) -> Run {
    Run(
        id: id,
        spec: WorkerSpec(cli: .claude, model: "haiku", prompt: "p", directory: "/work", access: .read, label: label),
        state: state, pid: 1, started: Date(timeIntervalSince1970: 0), ended: nil, output: nil, errorTail: nil
    )
}

@Test func theMaestroIsToldOfWorkersThatStoppedByThemselvesOnly() {
    let runs = [
        run("aaaa", label: "Inventário", state: .finished(exitCode: 0)),
        run("bbbb", state: .running),
        run("cccc", state: .cancelled),
        run("dddd", state: .finished(exitCode: 0)),
    ]
    let stopped = WorkerNotice.stopped(runs, wasRunning: ["aaaa", "bbbb", "cccc"])
    #expect(stopped.map(\.id) == ["aaaa"])
    #expect(WorkerNotice.text(stopped: stopped) == "[Vitra] O operário aaaa (Inventário) terminou. Leia a entrega com agent_wait.")
    #expect(WorkerNotice.text(stopped: []) == nil)
}

@Test func newsForTheMaestroWaitsForTheTurnToEndOrADraftAndNotForAScreenItCannotRead() {
    #expect(ProjectView.holdsNotice(isBusy: true, typed: "", sinceKey: nil))
    #expect(ProjectView.holdsNotice(isBusy: false, typed: "meio escrito", sinceKey: nil))
    #expect(!ProjectView.holdsNotice(isBusy: false, typed: "", sinceKey: 2))
    // The user is in another tab: claude hides the cursor and the prompt cannot be read.
    #expect(!ProjectView.holdsNotice(isBusy: false, typed: nil, sinceKey: nil))
    #expect(ProjectView.holdsNotice(isBusy: false, typed: nil, sinceKey: 5))
    #expect(!ProjectView.holdsNotice(isBusy: false, typed: nil, sinceKey: 31))
}

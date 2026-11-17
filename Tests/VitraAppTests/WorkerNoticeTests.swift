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

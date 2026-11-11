import AppKit
import Foundation
import Metal
import Testing
import VitraCore
@testable import VitraApp

/// A maestro that survived a reinstall: the stamp that tells it apart, the
/// armed one-shot that restarts it, and the header that has to make room.
struct MaestroStampTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vitra-stamp-\(UUID().uuidString)")
    }

    @Test func sameBuildIsCurrent() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroStamp.record(build: "100-2048", mode: .solo, for: "/tmp/proj", in: dir)
        let stamp = MaestroStamp.load(for: "/tmp/proj", in: dir)
        #expect(stamp?.build == "100-2048")
        #expect(stamp?.mode == .solo)
        #expect(!MaestroStamp.isOutdated(attached: true, recorded: stamp, current: "100-2048"))
    }

    @Test func differentBuildIsOutdated() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroStamp.record(build: "100-2048", mode: .orchestrator, for: "/tmp/proj", in: dir)
        #expect(MaestroStamp.isOutdated(attached: true, recorded: MaestroStamp.load(for: "/tmp/proj", in: dir), current: "200-4096"))
    }

    @Test func missingStampOnAttachIsOutdated() {
        let dir = directory()
        #expect(MaestroStamp.load(for: "/tmp/proj", in: dir) == nil)
        #expect(MaestroStamp.isOutdated(attached: true, recorded: nil, current: "200-4096"))
        // Unknown build of our own: nothing is marked rather than everything.
        #expect(!MaestroStamp.isOutdated(attached: true, recorded: nil, current: nil))
    }

    @Test func freshLaunchIsNeverOutdated() {
        #expect(!MaestroStamp.isOutdated(attached: false, recorded: nil, current: "200-4096"))
        let old = MaestroStamp(build: "1-1", mode: .solo, launched: Date(), path: "/tmp/proj")
        #expect(!MaestroStamp.isOutdated(attached: false, recorded: old, current: "200-4096"))
    }

    @Test func anotherProjectsStampIsNotRead() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroStamp.record(build: "1-1", mode: .solo, for: "/tmp/a", in: dir)
        // A file under b's name holding a's record (a digest collision, or a
        // hand-copied file) is not b's word.
        try FileManager.default.copyItem(at: MaestroStamp.file(for: "/tmp/a", in: dir), to: MaestroStamp.file(for: "/tmp/b", in: dir))
        #expect(MaestroStamp.load(for: "/tmp/b", in: dir) == nil)
    }

    @Test func buildStampFollowsTheExecutable() throws {
        let file = directory()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("one".utf8).write(to: file)
        let first = try #require(MaestroStamp.currentBuild(executable: file.path))
        try Data("one, rebuilt".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(MaestroStamp.currentBuild(executable: file.path) != first)
        #expect(MaestroStamp.currentBuild(executable: "/nonexistent/vitra") == nil)
    }
}

struct MaestroUpdateStateTests {
    @Test func armsOnlyAnOutdatedMaestro() {
        var state = MaestroUpdateState()
        state.arm()
        #expect(state.phase == .current)
        state.markOutdated()
        state.arm()
        #expect(state.phase == .armed)
    }

    @Test func firesOnWorkingToWaitingOnly() {
        var state = MaestroUpdateState()
        state.markOutdated()
        #expect(!state.fires(from: .working, to: .waiting), "not armed")
        state.arm()
        #expect(state.fires(from: .working, to: .waiting))
        #expect(!state.fires(from: .working, to: .needsPermission))
        #expect(!state.fires(from: .waiting, to: .waiting))
        #expect(!state.fires(from: nil, to: .waiting), "app start")
        #expect(!state.fires(from: .needsPermission, to: .working))
        #expect(!state.fires(from: .waiting, to: .working))
    }

    @Test func cancelLeavesItOutdated() {
        var state = MaestroUpdateState()
        state.markOutdated()
        state.arm()
        state.cancel()
        #expect(state.phase == .outdated)
        #expect(!state.fires(from: .working, to: .waiting))
    }

    @Test func relaunchClearsEverything() {
        var state = MaestroUpdateState()
        state.markOutdated()
        state.arm()
        state.relaunched()
        #expect(state.phase == .current)
        #expect(!state.fires(from: .working, to: .waiting))
        state.markOutdated()
        state.relaunched()
        #expect(state.phase == .current)
    }

    @Test func updatedPromptSaysNothingIsPending() {
        #expect(Maestro.updatedPrompt.contains("atualizado"))
        #expect(Maestro.updatedPrompt.contains("siga normalmente"))
    }
}

/// The header with the update pill, at the narrowest window.
@MainActor
struct HeaderFitTests {
    /// Every plate present, the update pill among them.
    private let crowded = HeaderFit.Widths(
        title: 52, modeFull: 140, modeShort: 92, model: 100, attention: 150,
        update: 160, updateCompact: 76, usage: 82, hasSession: true, branch: 64
    )

    @Test func everythingShowsWhenThereIsRoom() {
        let fit = HeaderFit.fit(width: 2000, crowded)
        #expect(fit == HeaderFit(abbreviatesMode: false, compactsUpdate: false, showsUsage: true, showsSession: true, showsPlace: true, showsBranch: true))
    }

    @Test func givesWayInOrder() {
        let full = HeaderFit.fit(width: 2000, crowded).needs(crowded)
        // Just short: the session goes first, and only it.
        let first = HeaderFit.fit(width: full - 1, crowded)
        #expect(!first.showsSession && first.showsUsage && first.showsPlace && first.showsBranch && !first.compactsUpdate)
        // Narrower and narrower: the update pill's words are the very last.
        let narrow = HeaderFit.fit(width: 400, crowded)
        #expect(narrow.compactsUpdate && !narrow.showsBranch && !narrow.showsUsage && narrow.abbreviatesMode)
    }

    @Test func fitsTheMinimumPaneWithTheUpdatePill() {
        let pane = CockpitWindowController.minSize.width - CockpitStyle.workersWidth - 1
        let fit = HeaderFit.fit(width: pane, crowded)
        #expect(fit.needs(crowded) <= pane)
        #expect(!fit.showsSession && !fit.showsUsage)
    }

    /// The real header, laid out at the narrowest window, with the maestro
    /// asking for permission and the update pill on: nothing past its edge.
    @Test func realHeaderStaysInsideItsPane() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitra-header-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = ProjectView(project: CockpitProject(path: folder.path), kit: TerminalKit(device: device, config: Config()), startsTerminal: false, showsHint: false)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: CockpitWindowController.minSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.show(model: MaestroModel(name: "Opus 5.5", effort: "high", session: "vitra · uma sessão de nome comprido"))
        view.show(usage: UsageLabel(text: "semana 87%", level: .warm))
        view.show(attention: "aguardando você · 59 min")
        for phase in [MaestroUpdateState.Phase.outdated, .armed] {
            view.showUpdate(phase)
            view.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            let header = try #require(view.header)
            for plate in header.arrangedSubviews where !plate.isHidden {
                #expect(plate.frame.maxX <= header.bounds.width - CockpitStyle.inset + 0.5, "\(phase): \(plate) runs past the header")
                #expect(plate.frame.width >= 1 || plate.fittingSize.width == 0, "\(phase): \(plate) squeezed to nothing")
            }
        }
    }
}

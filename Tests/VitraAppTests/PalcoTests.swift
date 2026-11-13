import Foundation
import Testing
import VitraOrchestrator
@testable import VitraApp

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func run(
    _ id: String, label: String? = nil, cli: WorkerCLI = .claude, model: String = "claude-haiku-5-5", kind: TaskKind = .implement,
    state: Run.State = .finished(exitCode: 0), startedAgo: TimeInterval = 60, took: TimeInterval = 30, score: Int? = nil,
    minutes: Int? = nil, silent: TimeInterval? = nil, branch: String? = nil, at reference: Date = now
) -> Run {
    let started = reference.addingTimeInterval(-startedAgo)
    let running = state == .running
    return Run(
        id: id,
        spec: WorkerSpec(cli: cli, model: model, prompt: label ?? id, directory: "/tmp/p", label: label ?? id, kind: kind, minutes: minutes),
        state: state, pid: nil, started: started, ended: running ? nil : started.addingTimeInterval(took),
        output: nil, errorTail: nil, branch: branch,
        rating: score.map { Rating(score: $0, note: nil, rated: now) }, silentFor: silent
    )
}

// MARK: Which runs are shown

@Test func stageShowsRunningAndRecentlyFinishedButNotOld() {
    let runs = [
        run("running", state: .running, startedAgo: 3_000),
        run("recent", startedAgo: 300, took: 60),
        run("old", startedAgo: 3_600, took: 60),
        run("justOutside", startedAgo: StageModel.finishedLinger + 100, took: 10),
    ]

    let ids = StageModel.nodes(from: runs, now: now).map(\.id)

    #expect(Set(ids) == ["running", "recent"])
}

@Test func stageKeepsTheTwelveMostRelevantAndPrefersRunningOnes() {
    var runs = (0..<10).map { run("done\($0)", startedAgo: 60 + Double($0) * 10, took: 5) }
    runs += (0..<4).map { run("live\($0)", state: .running, startedAgo: 500 + Double($0)) }

    let ids = StageModel.nodes(from: runs, now: now).map(\.id)

    #expect(ids.count == StageModel.maxNodes)
    #expect((0..<4).allSatisfy { ids.contains("live\($0)") })
}

@Test func stageNodesComeOldestStartFirst() {
    let nodes = StageModel.nodes(from: [run("b", startedAgo: 100), run("a", startedAgo: 200), run("c", startedAgo: 50)], now: now)

    #expect(nodes.map(\.id) == ["a", "b", "c"])
}

@Test func finishedNodeFadesOnlyTowardTheEndOfItsStay() {
    let fresh = StageModel.nodes(from: [run("x", startedAgo: 120, took: 60)], now: now)[0]
    let old = StageModel.nodes(from: [run("y", startedAgo: 860 + 60, took: 60)], now: now)[0]

    #expect(fresh.emphasis == 1)
    #expect(old.emphasis < 1 && old.emphasis >= 0.5)
}

@Test func nextExpiryIsWhenTheEarliestFinishedWorkerIsDue() {
    let nodes = StageModel.nodes(from: [run("live", state: .running), run("done", startedAgo: 300, took: 100)], now: now)

    let due = StageModel.nextExpiry(nodes)

    #expect(due == now.addingTimeInterval(-200 + StageModel.finishedLinger))
    #expect(StageModel.nextExpiry(StageModel.nodes(from: [run("live", state: .running)], now: now)) == nil)
}

// MARK: Audits

@Test func auditMatchesTheDeliveryItIsLabelledAfter() {
    let runs = [
        run("d1", label: "Revisar o diff", startedAgo: 600),
        run("d2", label: "Outra coisa", startedAgo: 500),
        run("a1", label: "auditoria: Revisar o diff", kind: .review, state: .running, startedAgo: 100),
    ]

    #expect(StageModel.deliveryIDs(forAuditsIn: runs) == ["a1": "d1"])
    let nodes = StageModel.nodes(from: runs, now: now)
    #expect(nodes.first { $0.id == "a1" }?.auditOf == "d1")
    #expect(nodes.first { $0.id == "a1" }?.isAudit == true)
    #expect(nodes.first { $0.id == "d1" }?.isAudit == false)
}

@Test func auditOfAnUnshownDeliveryHasNoParentAndAuditOfSameLabelTakesTheLatestEarlierRun() {
    let orphan = [run("a1", label: "auditoria: Sumiu", kind: .review, state: .running)]
    #expect(StageModel.deliveryIDs(forAuditsIn: orphan).isEmpty)

    let twins = [
        run("old", label: "Mesmo nome", startedAgo: 900),
        run("new", label: "Mesmo nome", startedAgo: 400),
        run("a1", label: "auditoria: Mesmo nome", kind: .review, state: .running, startedAgo: 100),
    ]
    #expect(StageModel.deliveryIDs(forAuditsIn: twins)["a1"] == "new")
}

@Test func auditWithoutALabelIsMatchedByTheDeliverysId() {
    let runs = [run("abc12345", startedAgo: 600), run("a1", label: "auditoria: abc12345", kind: .review, state: .running)]

    #expect(StageModel.deliveryIDs(forAuditsIn: runs) == ["a1": "abc12345"])
}

// MARK: Deadline

@Test func deadlineFractionUsesTheSpecsMinutesElseTheDefaults() {
    let started = now.addingTimeInterval(-9 * 60)
    #expect(StageModel.deadlineFraction(started: started, ended: nil, now: now, minutes: 45) == 0.2)
    #expect(StageModel.deadlineFraction(started: started, ended: nil, now: now, minutes: 8) == 1)
    #expect(StageModel.deadlineFraction(started: started, ended: started.addingTimeInterval(90), now: now, minutes: 45) == 90.0 / 2700)

    let normal = StageModel.nodes(from: [run("w", state: .running, startedAgo: 9 * 60)], now: now)[0]
    let audit = StageModel.nodes(from: [run("a", label: "auditoria: w", kind: .review, state: .running, startedAgo: 4 * 60)], now: now)[0]
    let custom = StageModel.nodes(from: [run("c", state: .running, startedAgo: 9 * 60, minutes: 18)], now: now)[0]
    #expect(normal.deadlineFraction == 0.2)
    #expect(audit.deadlineFraction == 0.5)
    #expect(custom.deadlineFraction == 0.5)
}

@Test func silentWorkerIsDimmedOnlyPastTwoMinutes() {
    let quiet = StageModel.nodes(from: [run("a", state: .running, silent: 119)], now: now)[0]
    let silent = StageModel.nodes(from: [run("b", state: .running, silent: 121)], now: now)[0]

    #expect(!quiet.isSilent)
    #expect(silent.isSilent)
}

// MARK: Words

@Test func nodeStateTextTellsElapsedTimeOrOutcome() {
    func node(_ run: Run) -> StageNode { StageModel.nodes(from: [run], now: now)[0] }

    #expect(node(run("r", state: .running, startedAgo: 134)).stateText == "2:14")
    #expect(node(run("d", score: 5)).stateText == "pronto 5/5")
    #expect(node(run("l", state: .lost)).stateText == "perdido")
    #expect(node(run("c", state: .cancelled)).stateText == "cancelado")
    #expect(node(run("u", score: 2)).outcome == .failed)
    #expect(StageModel.clock(3_725) == "1:02:05")
}

@Test func glyphNamesTheModelFamily() {
    #expect(StageModel.glyph(model: "claude-opus-5-5") == "Op")
    #expect(StageModel.glyph(model: "claude-sonnet-5-5") == "So")
    #expect(StageModel.glyph(model: "opencode/deepseek-v4.1-flash-free") == "Ds")
    #expect(StageModel.glyph(model: "gemini-3-flash") == "Gem")
    #expect(StageModel.glyph(model: "zeta-9") == "Ze")
    #expect(StageModel.glyph(model: "") == "?")
}

@Test func coreTitleDropsTheVendorAndTheContextNote() {
    #expect(StageModel.coreTitle("Claude Opus 5.5 (1M context)") == "Opus 5.5")
    #expect(StageModel.coreTitle("Opus 5.5") == "Opus 5.5")
    #expect(StageModel.coreTitle(nil) == "claude")
    #expect(StageModel.percent(inUsageText: "semana 62%") == 62)
    #expect(StageModel.percent(inUsageText: "") == nil)
}

// MARK: Angles

@Test func aWorkerKeepsItsSlotWhileOthersComeAndGo() {
    var book = SlotBook()
    book.update(ids: ["a", "b", "c"])
    let before = book.slots

    book.update(ids: ["a", "c", "d", "e"])

    #expect(book.slots["a"] == before["a"])
    #expect(book.slots["c"] == before["c"])
    #expect(book.slots["b"] == nil)
    #expect(Set(book.slots.values).count == book.slots.count)
}

@Test func slotsSpreadWorkersOutAndFillTheOuterOrbitFirst() {
    var book = SlotBook()
    book.update(ids: ["a", "b"])
    #expect(Set(book.slots.values) == [0, 6])

    book.update(ids: ["a", "b", "c", "d", "e", "f"])
    #expect(book.slots.values.allSatisfy { $0 % 2 == 0 })

    book.update(ids: (0..<12).map(String.init))
    #expect(Set(book.slots.values) == Set(0..<12))
}

@Test func aThirteenthWorkerGetsNoSlotAndNothingMoves() {
    var book = SlotBook()
    book.update(ids: (0..<12).map(String.init))
    let before = book.slots

    book.update(ids: (0..<13).map(String.init))

    #expect(book.slots == before)
}

@Test func slotsLieInsideTheStageAndApartFromEachOther() {
    let geometry = StageGeometry(size: CGSize(width: 420, height: 432))
    let points = (0..<SlotBook.count).map(geometry.position(ofSlot:))

    for point in points {
        #expect(point.x >= 0 && point.x <= 420 && point.y >= 0 && point.y <= 432 - StageGeometry.trunkHeight)
    }
    for (i, a) in points.enumerated() {
        for b in points[(i + 1)...] { #expect(hypot(a.x - b.x, a.y - b.y) > 2 * StageGeometry.nodeRadius) }
    }
}

@Test func anAuditHangsLevelBesideItsDeliveryAndStaysOnTheStage() {
    let geometry = StageGeometry(size: CGSize(width: 420, height: 432))
    let right = CGPoint(x: 300, y: 120)
    let farLeft = CGPoint(x: 14, y: 200)

    #expect(geometry.auditPosition(besideDelivery: right).y == right.y)
    #expect(geometry.auditPosition(besideDelivery: right).x > right.x)
    #expect(geometry.auditPosition(besideDelivery: farLeft).x > farLeft.x)
}

@Test func commitDotsFillFromTheRight() {
    let geometry = StageGeometry(size: CGSize(width: 420, height: 432))

    #expect(geometry.commitPosition(index: 0).x > geometry.commitPosition(index: 1).x)
    #expect(geometry.commitPosition(index: 0).y == geometry.trunkY)
}

@Test func hitTestPicksTheNodeUnderThePointerAndPrefersTheSmallerOne() {
    let nodes: [(id: String, point: CGPoint, radius: CGFloat)] = [
        ("big", CGPoint(x: 100, y: 100), 16), ("small", CGPoint(x: 120, y: 100), 9), ("far", CGPoint(x: 300, y: 300), 16),
    ]

    #expect(StageGeometry.hit(CGPoint(x: 101, y: 100), in: nodes) == "big")
    #expect(StageGeometry.hit(CGPoint(x: 112, y: 100), in: nodes) == "small")
    #expect(StageGeometry.hit(CGPoint(x: 200, y: 200), in: nodes) == nil)
}

@Test func linkCurveStartsAndEndsOnItsPoints() {
    let curve = LinkCurve(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), bend: 1)

    #expect(curve.point(at: 0) == curve.from)
    #expect(curve.point(at: 1) == curve.to)
    #expect(curve.reversed.point(at: 0) == curve.to)
    #expect(curve.point(at: 0.5) != CGPoint(x: 60, y: 35))
}

// MARK: Timeline

private func lane(_ id: String, auditOf: String? = nil, startedAgo: TimeInterval) -> StageNode {
    let label = auditOf.map { "auditoria: \($0)" }
    return StageModel.nodes(from: [run(id, label: label ?? id, kind: auditOf == nil ? .implement : .review, startedAgo: startedAgo)], now: now)[0]
}

@Test func lanesGoInStartOrderWithEachAuditUnderItsDelivery() {
    let runs = [
        run("late", startedAgo: 100),
        run("first", startedAgo: 900),
        run("aud", label: "auditoria: first", kind: .review, startedAgo: 700),
        run("middle", startedAgo: 500),
    ]
    let nodes = StageModel.nodes(from: runs, now: now)

    let order = TimelineLayout.order(nodes).map(\.id)

    #expect(order == ["first", "aud", "middle", "late"])
}

@Test func auditLanesAreThinnerAndAllLanesFitTheHeight() {
    let runs = [run("d", startedAgo: 900), run("a", label: "auditoria: d", kind: .review, startedAgo: 700)]
        + (0..<10).map { run("x\($0)", startedAgo: 100 + Double($0)) }
    let nodes = StageModel.nodes(from: runs, now: now)

    let lanes = TimelineLayout.lanes(nodes, height: 200)

    #expect(lanes.count == nodes.count)
    #expect((lanes.last.map { $0.minY + $0.height } ?? 0) <= 200.001)
    let audit = lanes.first { $0.isAudit }
    let normal = lanes.first { !$0.isAudit }
    #expect((audit?.height ?? 0) < (normal?.height ?? 0))
    #expect(TimelineLayout.lanes([], height: 100).isEmpty)
}

@Test func timelineZoomsToTheOldestShownRunUpToThirtyMinutes() {
    let young = StageModel.nodes(from: [run("a", state: .running, startedAgo: 600)], now: now)
    let layout = TimelineLayout(nodes: young, now: now, width: 300)
    #expect(layout.start < now.addingTimeInterval(-600) && layout.start > now.addingTimeInterval(-700))

    let ancient = StageModel.nodes(from: [run("b", state: .running, startedAgo: 3 * 3_600)], now: now)
    #expect(TimelineLayout(nodes: ancient, now: now, width: 300).start == now.addingTimeInterval(-TimelineLayout.window))

    let fresh = StageModel.nodes(from: [run("c", state: .running, startedAgo: 5)], now: now)
    #expect(TimelineLayout(nodes: fresh, now: now, width: 300).span >= TimelineLayout.minimumSpan)
}

@Test func timeMapsLinearlyToXAndBarsAreClamped() {
    let nodes = StageModel.nodes(from: [run("a", state: .running, startedAgo: 3 * 3_600)], now: now)
    let layout = TimelineLayout(nodes: nodes, now: now, width: 400)

    #expect(layout.x(layout.start) == 0)
    #expect(abs(layout.x(layout.end) - 400) < 0.001)
    #expect(abs(layout.x(layout.start.addingTimeInterval(layout.span / 2)) - 200) < 0.001)
    let bar = layout.bar(of: nodes[0], now: now)
    #expect(bar.minX == 0)
    #expect(bar.maxX == layout.x(now))
}

@Test func aBarThatJustStartedStillHasWidth() {
    let nodes = StageModel.nodes(from: [run("a", state: .running, startedAgo: 0)], now: now)
    let layout = TimelineLayout(nodes: nodes, now: now, width: 400)

    let bar = layout.bar(of: nodes[0], now: now)

    #expect(bar.maxX - bar.minX >= 3)
}

@Test func gridlinesFallOnWholeClockMinutesAndKeepTheirDistance() {
    let utc = TimeZone(identifier: "UTC")!
    // 19:43:00 UTC.
    let at = Date(timeIntervalSince1970: 19 * 3_600 + 43 * 60)
    let nodes = StageModel.nodes(from: [run("a", state: .running, startedAgo: 20 * 60, at: at)], now: at)
    let layout = TimelineLayout(nodes: nodes, now: at, width: 300)

    let lines = layout.lines(timeZone: utc)

    #expect(!lines.isEmpty)
    #expect(lines.allSatisfy { $0.date <= at })
    #expect(lines.allSatisfy { Int($0.date.timeIntervalSince1970) % 300 == 0 })
    #expect(lines.last?.label == "19:40")
    for pair in zip(lines, lines.dropFirst()) { #expect(pair.1.x - pair.0.x >= TimelineLayout.minimumLineGap - 0.001) }
}

@Test func gridlinesFollowTheZonesClockNotTheEpoch() {
    let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    let at = Date(timeIntervalSince1970: 3_600 * 12)
    let nodes = StageModel.nodes(from: [run("a", state: .running, startedAgo: 20 * 60, at: at)], now: at)

    let lines = TimelineLayout(nodes: nodes, now: at, width: 300).lines(timeZone: kolkata)

    #expect(lines.allSatisfy { $0.label.hasSuffix("0") || $0.label.hasSuffix("5") })
    #expect(TimelineLayout.clock(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!) == "00:00")
}

// MARK: Liveness and merging

@Test func animationsRunOnlyWhenVisibleRunningAndMotionIsWelcome() {
    #expect(StageLiveness.animates(isOnScreen: true, hasRunning: true, reduceMotion: false))
    #expect(!StageLiveness.animates(isOnScreen: false, hasRunning: true, reduceMotion: false))
    #expect(!StageLiveness.animates(isOnScreen: true, hasRunning: false, reduceMotion: false))
    #expect(!StageLiveness.animates(isOnScreen: true, hasRunning: true, reduceMotion: true))
}

@Test func aBranchThatVanishesAfterBeingSeenIsAMerge() {
    var tracker = MergeTracker()
    let branches = ["r1": "vitra/r1", "r2": "vitra/r2"]

    #expect(tracker.update(branches: branches, existing: ["main", "vitra/r1", "vitra/r2"]).isEmpty)
    #expect(tracker.update(branches: branches, existing: ["main", "vitra/r2"]) == ["r1"])
    #expect(tracker.update(branches: branches, existing: ["main", "vitra/r2"]).isEmpty)
    #expect(tracker.merged == ["r1"])
}

@Test func aBranchNeverSeenIsNotAMerge() {
    var tracker = MergeTracker()

    #expect(tracker.update(branches: ["r1": "vitra/r1"], existing: ["main"]).isEmpty)
    #expect(tracker.merged.isEmpty)
}

@Test func anAcceptedEditWhoseBranchIsGoneIsAMergeEvenIfNeverSeenAndOnlyOnce() {
    var tracker = MergeTracker()
    // Merged before the tab opened: never seen, rated 4+.
    #expect(tracker.update(branches: ["r1": "vitra/r1"], existing: ["main"], accepted: ["r1"]) == ["r1"])
    #expect(tracker.update(branches: ["r1": "vitra/r1"], existing: ["main"], accepted: ["r1"]).isEmpty)
    // Still there: not yet merged, however well rated.
    #expect(tracker.update(branches: ["r2": "vitra/r2"], existing: ["vitra/r2"], accepted: ["r2"]).isEmpty)
    #expect(tracker.update(branches: ["r2": "vitra/r2"], existing: [], accepted: ["r2"]) == ["r2"])
    #expect(tracker.merged == ["r1", "r2"])
}

@Test func auditVerdictIsReadFromTheAnswersFirstLine() {
    #expect(StageModel.auditVerdict("Verdict: ship\nall good") == "ok")
    #expect(StageModel.auditVerdict("SHIP AFTER FIXES — two nits") == "corrigir")
    #expect(StageModel.auditVerdict("Do not ship: breaks the build") == "não")
    #expect(StageModel.auditVerdict("Looked at three files\nship") == nil)
    #expect(StageModel.auditVerdict(nil) == nil)
}

@Test(arguments: [CGSize(width: 420, height: 520), CGSize(width: 720, height: 420)])
func twelveNodesWordsKeepClearOfEveryOtherNodeAndWords(size: CGSize) {
    let geometry = StageGeometry(size: size)
    var book = SlotBook()
    let ids = (0..<12).map { "n\($0)" }
    book.update(ids: ids)
    let discs = ids.map { (id: $0, point: geometry.position(ofSlot: book.slots[$0]!), radius: StageGeometry.nodeRadius) }
    let sides = geometry.textSides(labelled: ids, discs: discs)
    let rects = Dictionary(uniqueKeysWithValues: discs.map { ($0.id, StageGeometry.textRect(at: $0.point, side: sides[$0.id]!)) })
    for disc in discs {
        let rect = rects[disc.id]!
        for other in discs where other.id != disc.id {
            #expect(StageGeometry.distance(from: rect, to: other.point) - other.radius >= StageGeometry.textClearance, "\(disc.id) words on \(other.id) disc")
            #expect(StageGeometry.gap(rect, rects[other.id]!) >= StageGeometry.textClearance, "\(disc.id) words on \(other.id) words")
        }
    }
}

@Test func onlyTheLastTenMergesAreKept() {
    var tracker = MergeTracker()
    let branches = Dictionary(uniqueKeysWithValues: (0..<14).map { (String(format: "r%02d", $0), "b\($0)") })
    _ = tracker.update(branches: branches, existing: Set(branches.values))
    _ = tracker.update(branches: branches, existing: [])

    #expect(tracker.merged.count == 14)
    #expect(tracker.recent().count == StageGeometry.commitsShown)
    #expect(tracker.recent().last == "r13")
}

// MARK: The views' gating, without looking at motion

import AppKit
import QuartzCore

/// How many layers under `layer` have an animation running with this key.
private func animationCount(_ layer: CALayer?, key: String) -> Int {
    guard let layer else { return 0 }
    let own = layer.animation(forKey: key) == nil ? 0 : 1
    return own + (layer.sublayers ?? []).reduce(0) { $0 + animationCount($1, key: key) }
}

/// How many repeating animations of any key are attached anywhere under `layer`.
private func repeatingCount(_ layer: CALayer?) -> Int {
    guard let layer else { return 0 }
    let own = (layer.animationKeys() ?? []).filter { layer.animation(forKey: $0)?.repeatCount ?? 0 > 1 }.count
    return own + (layer.sublayers ?? []).reduce(0) { $0 + repeatingCount($1) }
}

@MainActor
private func stage(running: Bool = true, reduceMotion: Bool = false) -> StageView {
    let view = StageView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
    view.reduceMotion = reduceMotion
    view.layoutSubtreeIfNeeded()
    let runs = [run("a", state: running ? .running : .finished(exitCode: 0), startedAgo: 120), run("b", startedAgo: 200)]
    view.update(StageState(nodes: StageModel.nodes(from: runs, now: now), now: now), animated: false)
    return view
}

@MainActor
@Test func stageHasNoRepeatingAnimationUntilItIsMadeLive() {
    let view = stage()

    #expect(repeatingCount(view.layer) == 0)

    view.setLive(true)
    #expect(animationCount(view.layer, key: "travel") > 0)
    #expect(animationCount(view.layer, key: "breath") > 0)
    #expect(animationCount(view.layer, key: "turn") == 1)
    #expect(animationCount(view.layer, key: "glow") == 1)

    view.setLive(false)
    #expect(repeatingCount(view.layer) == 0)
}

@MainActor
@Test func stageWithNothingRunningStaysStaticEvenWhenLive() {
    let view = stage(running: false)

    view.setLive(true)

    #expect(repeatingCount(view.layer) == 0)
}

@MainActor
@Test func stageIgnoresLivenessWhenMotionIsReduced() {
    let view = stage(reduceMotion: true)

    view.setLive(true)

    #expect(repeatingCount(view.layer) == 0)
}

@MainActor
@Test func stageStopsAnimatingWhenItsLastWorkerFinishes() {
    let view = stage()
    view.setLive(true)

    let done = [run("a", startedAgo: 120), run("b", startedAgo: 200)]
    view.update(StageState(nodes: StageModel.nodes(from: done, now: now), now: now), animated: false)

    #expect(repeatingCount(view.layer) == 0)
}

@MainActor
@Test func timelineSheenRunsOnlyWhileLive() {
    let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    view.layoutSubtreeIfNeeded()
    view.update(StageModel.nodes(from: [run("a", state: .running, startedAgo: 200)], now: now), now: now, glide: false)
    #expect(repeatingCount(view.layer) == 0)

    view.setLive(true)
    #expect(animationCount(view.layer, key: "slide") == 1)

    view.setLive(false)
    #expect(repeatingCount(view.layer) == 0)
}

@MainActor
@Test func timelineSheenSpansTheGrownBarAndIsAbsentWithReducedMotion() {
    let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    view.layoutSubtreeIfNeeded()
    // An older run holds the window at its full half hour.
    let runs = [run("old", state: .running, startedAgo: 1_790), run("a", state: .running, startedAgo: 60)]
    view.update(StageModel.nodes(from: runs, now: now), now: now, glide: false)
    view.setLive(true)
    // The sweeps' total reach, over every running bar.
    let sweep = { () -> CGFloat in
        (view.layer?.sublayers ?? []).flatMap { $0.sublayers ?? [] }
            .compactMap { ($0.animation(forKey: "slide") as? CABasicAnimation)?.toValue as? CGFloat }
            .reduce(0, +)
    }
    let first = sweep()
    // Twenty minutes on, the newer run's bar is far longer, and so is its sweep.
    let later = now.addingTimeInterval(1_200)
    view.update(StageModel.nodes(from: runs, now: later), now: later, glide: false)
    #expect(sweep() > first + 40)

    let reduced = TimelineView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    reduced.reduceMotion = true
    reduced.layoutSubtreeIfNeeded()
    reduced.update(StageModel.nodes(from: runs, now: now), now: now, glide: false)
    reduced.setLive(true)
    let sheens = reduced.layer?.sublayers?.compactMap { $0.sublayers?.first as? CAGradientLayer } ?? []
    let shown = sheens.filter { !$0.isHidden }.count
    #expect(!sheens.isEmpty)
    #expect(shown == 0)
}

@MainActor
@Test func emptyCoreBreathesOnlyWhileVisibleAndNotWithReducedMotion() {
    let view = stage(running: false)
    #expect(animationCount(view.layer, key: "idle") == 0)
    view.setVisible(true)
    #expect(animationCount(view.layer, key: "idle") == 1)
    view.setVisible(false)
    #expect(repeatingCount(view.layer) == 0)

    let still = stage(running: false, reduceMotion: true)
    still.setVisible(true)
    #expect(repeatingCount(still.layer) == 0)
}

@MainActor
@Test func palcoOutOfSightKeepsNoLayersAndNoAnimations() {
    let palco = PalcoView(repository: nil)
    palco.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
    // Not in a window: nothing can be seen.
    palco.show([run("a", state: .running, startedAgo: 120)], now: now)
    palco.layoutSubtreeIfNeeded()

    #expect(repeatingCount(palco.layer) == 0)
    #expect(animationCount(palco.layer, key: "enter") == 0)
}

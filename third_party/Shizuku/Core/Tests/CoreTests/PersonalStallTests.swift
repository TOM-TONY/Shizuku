import Foundation
import Testing
@testable import Core

private let stallScene = PersonalScene(app: "com.example.chat", shape: .line, mode: .new, reply: false)

@Test func stallPositionsReadOnlyTheSuffixAndInputState() {
    #expect(PersonalStall.position(left: "", composing: false, candidates: false, confirming: false) == .paragraph)
    #expect(PersonalStall.position(left: "本文\n", composing: false, candidates: false, confirming: false) == .paragraph)
    #expect(PersonalStall.position(left: "本文。", composing: false, candidates: false, confirming: false) == .sentence)
    #expect(PersonalStall.position(left: "本文は", composing: false, candidates: false, confirming: false) == .particle)
    #expect(PersonalStall.position(left: "本文", composing: false, candidates: false, confirming: false) == .middle)
    #expect(PersonalStall.position(left: "", composing: true, candidates: false, confirming: false) == .conversion)
    #expect(PersonalStall.position(left: "", composing: true, candidates: true, confirming: true) == .candidates)
    #expect(PersonalStall.position(left: "", composing: true, candidates: false, confirming: true) == .confirmation)
}

@Test func stallEventsAThroughEHaveOnlySpecifiedNumbersAndNoRepeatedDepthOrDeletion() {
    var tracker = PersonalStall.Tracker(now: 0, entryKnown: true)
    let e = tracker.beforeKey(scene: stallScene, now: 11, composing: false, position: .paragraph, threshold: nil, emptyField: true, deletedCharacters: 0)
    #expect(e.map(\.event) == [.empty] && e[0].seconds == 11)
    let a = tracker.beforeKey(scene: stallScene, now: 13, composing: true, position: .conversion, threshold: 1, emptyField: false, deletedCharacters: 0)
    #expect(a.map(\.event) == [.interval] && a[0].seconds == 2)
    let c = tracker.afterKey(scene: stallScene, now: 13, wasComposing: true, isEmpty: false, depth: 3)
    #expect(c.map(\.event) == [.depth] && c[0].depth == 3)
    #expect(tracker.afterKey(scene: stallScene, now: 14, wasComposing: true, isEmpty: false, depth: 4).isEmpty)
    let b = tracker.afterKey(scene: stallScene, now: 15, wasComposing: true, isEmpty: true, depth: nil)
    #expect(b.map(\.event) == [.abandoned])
    let d = tracker.beforeKey(scene: stallScene, now: 16, composing: false, position: .middle, threshold: nil, emptyField: false, deletedCharacters: 4)
    #expect(d.map(\.event) == [.deleted] && d[0].deleted == 4)
    #expect(tracker.beforeKey(scene: stallScene, now: 17, composing: false, position: .middle, threshold: nil, emptyField: false, deletedCharacters: 5).isEmpty)
    tracker.didCommit = true
    #expect(tracker.afterKey(scene: stallScene, now: 18, wasComposing: true, isEmpty: true, depth: nil).isEmpty)
    var fresh = PersonalStall.Tracker(now: 0)
    #expect(fresh.beforeKey(scene: stallScene, now: 10, composing: false, position: .paragraph, threshold: nil, emptyField: true, deletedCharacters: 3).isEmpty)
}

@Test func stallQuantileUsesTwoHundredIntervalsInTheFinestAvailableLevelWithoutIdleClamping() {
    func histogram(_ n: Int, seconds: Double) -> PersonalRhythm.Histogram {
        var h = PersonalRhythm.Histogram()
        for _ in 0..<n { PersonalRhythm.add(&h, seconds: seconds, now: 1) }
        return h
    }
    let values = [stallScene.key: histogram(199, seconds: 0.2), "app:" + stallScene.app: histogram(200, seconds: 10), "global": histogram(200, seconds: 20)]
    #expect((PersonalStall.threshold(scene: stallScene, intervals: values) ?? 0) > 9)
    #expect(PersonalStall.threshold(scene: stallScene, intervals: [stallScene.key: histogram(200, seconds: 0.2)])! < 0.3)
    #expect(PersonalStall.threshold(scene: stallScene, intervals: ["global": histogram(199, seconds: 1)]) == nil)
    #expect(PersonalRhythm.bucket(0.1) == 1)
    #expect(PersonalRhythm.bucket(0.11201) == 2)
    #expect(PersonalRhythm.bucket(60) < PersonalRhythm.bucketCount)
}

@Test func stallWeakLabelsAndHidRoundingDoNotInferReadingOutsideOneSecond() {
    let hid = PersonalStall.HID(mouse: 2.4, scroll: 0.9, click: nil)
    #expect(hid.mouse == 2 && hid.scroll == 1 && hid.click == nil)
    #expect(PersonalStall.label(action: .typing, delay: 0.1, hid: hid, away: false) == .reading)
    #expect(PersonalStall.label(action: .typing, delay: 5.001, hid: hid, away: false) == .unknown)
    #expect(PersonalStall.label(action: .typing, delay: 0, hid: .init(mouse: 0, scroll: 1.01, click: nil), away: false) == .unknown)
    for action: PersonalStall.Action in [.backspace, .reconvert, .continuation] {
        #expect(PersonalStall.label(action: action, delay: 1, hid: nil, away: false) == .thinking)
        #expect(PersonalStall.label(action: action, delay: 1, hid: hid, away: true) == .away)
    }
    let unreadable = PersonalStall.HID(mouse: .nan, scroll: -.infinity, click: -1)
    #expect(unreadable.mouse == nil && unreadable.scroll == nil && unreadable.click == nil)
}

@Test func stallLinksExpireAtOneHundredTwentySecondsAndResetWithTheField() {
    var tracker = PersonalStall.Tracker(now: 0)
    let first = PersonalStall.Record(scene: stallScene, event: .abandoned, position: .conversion, now: 0)
    tracker.append(first)
    #expect(tracker.linkable(now: 120) == [first.id])
    tracker.append(first)
    #expect(tracker.linkable(now: 120.001).isEmpty)
    tracker.append(first)
    tracker = .init(now: 10)
    #expect(tracker.linkable(now: 10).isEmpty && tracker.burstCharacters == 0)
}

@Test func stallBurstHistogramRetainsOnlyCharacterCounts() throws {
    var histogram = PersonalStall.Burst()
    for n in [2, 4, 6, 8, 10] { histogram.add(n) }
    #expect(histogram.median == 6)
    let decoded = try JSONDecoder().decode(PersonalStall.Burst.self, from: JSONEncoder().encode(histogram))
    #expect(decoded == histogram)
    var even = PersonalStall.Burst(); even.add(4); even.add(6)
    #expect(even.median == 5)
    histogram.add(0); #expect(histogram.counts.count == 5)
}

@Test @MainActor func stallTablesParticipateInExportSnapshotAppDeletionRetentionAndDeleteAll() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersonalStore(url: directory.appendingPathComponent("personal.sqlite"))
    let learner = PersonalLearner(storeURL: nil); learner.attachStoreForTesting(store)
    let other = PersonalScene(app: "com.example.mail", shape: .line, mode: .new, reply: false)
    let now = Date().timeIntervalSince1970
    for scene in [stallScene, other] {
        let record = PersonalStall.Record(scene: scene, event: .interval, position: .conversion, seconds: 2, now: now)
        learner.recordStall(record)
        learner.annotateStall(id: record.id, hid: .init(mouse: 2, scroll: nil, click: 1), label: .reading)
        learner.linkStalls([record.id], commitID: 1, now: now + 120)
        learner.recordStallInterval(scene: scene, seconds: 0.5, now: now)
        learner.recordBurst(scene: scene, characters: 10, now: now)
    }
    learner.flush()
    #expect(try store.scalarInt("SELECT COUNT(*) FROM stalls WHERE commit_id=1 AND weak_label=2") == 2)
    let summary = learner.stallSummary()
    #expect(summary.contains("a:2") && summary.contains("バースト"))
    let export = try learner.export(to: directory.appendingPathComponent("export.jsonl"))
    let text = try String(contentsOf: export, encoding: .utf8)
    for table in ["stalls", "stall_intervals", "stall_bursts"] { #expect(text.contains("\"table\":\"" + table + "\"")) }
    let snapshot = directory.appendingPathComponent("snapshot.sqlite")
    try store.snapshot(to: snapshot)
    #expect(try LabSnapshot.readCommits(url: snapshot).isEmpty)
    _ = try LabSnapshot.readUpperBoundAuxiliary(url: snapshot)
    learner.forgetApp(stallScene.app); learner.flush()
    #expect(try store.scalarInt("SELECT COUNT(*) FROM stalls") == 1)
    #expect(try store.scalarInt("SELECT COUNT(*) FROM stall_bursts") == 1)
    #expect(try PersonalStall.intervalRows(store: store)["global"]?.total == 1)
    // 古い行だけを保持期間の外へ置く。本人の記録には触れない。
    try store.execute("UPDATE stalls SET ts=0")
    try store.execute("UPDATE stall_bursts SET ts=0")
    try PersonalLearner.pruneExpired(store: store, now: Date())
    #expect(try store.scalarInt("SELECT COUNT(*) FROM stalls") == 0)
    #expect(try store.scalarInt("SELECT COUNT(*) FROM stall_bursts") == 0)
    learner.deleteAll(); learner.flush()
    for table in ["stalls", "stall_intervals", "stall_bursts"] { #expect(try store.scalarInt("SELECT COUNT(*) FROM " + table) == 0) }
    try await Task.sleep(for: .milliseconds(30))
    learner.flush()
}

@Test func stallUnknownFieldEntryNeverInventsAnEmptyFieldWait() {
    var tracker = PersonalStall.Tracker(now: 0)
    #expect(tracker.beforeKey(scene: stallScene, now: 100, composing: false, position: .paragraph,
        threshold: nil, emptyField: true, deletedCharacters: 0).isEmpty)
}

@Test func stallAwayAndMicrophoneWindowsAreObservationOnlyAndBounded() {
    #expect(PersonalStall.awayStart(lastKey: 0, now: 89.999) == nil)
    #expect(PersonalStall.awayStart(lastKey: 10, now: 100) == 100)
    #expect(PersonalStall.microphoneDuration(start: 10, end: 1810) == 1800)
    #expect(PersonalStall.microphoneDuration(start: 10, end: 1810.001) == nil)
    #expect(PersonalStall.microphoneDuration(start: 10, end: 9) == nil)
}

@Test func stallObservationGateNeverInvokesQueuedReadsAfterDisableOrGenerationChange() {
    let gate = PersonalObservationGate()
    var calls = 0
    func read() -> PersonalStall.HID { calls += 1; return .init(mouse: 0, scroll: nil, click: nil) }
    #expect(gate.sample(generation: 0, read) == nil && calls == 0)
    gate.set(enabled: true, generation: 1)
    #expect(gate.sample(generation: 1, read) != nil && calls == 1)
    gate.set(enabled: false, generation: 2)
    #expect(gate.sample(generation: 1, read) == nil && calls == 1)
    gate.set(enabled: true, generation: 3)
    #expect(gate.sample(generation: 1, read) == nil && calls == 1)
    #expect(gate.sample(generation: 3, read) != nil && calls == 2)
}

@Test func stallEnvironmentKeepsUnlockTimeAcrossAnExcludedAppWithoutRecordingThere() {
    var environment = PersonalEnvironment()
    environment.configure(enabled: true, scene: stallScene)
    #expect(environment.beginAway(now: 10) == stallScene)
    environment.configure(enabled: true, scene: nil)
    #expect(environment.endAway(now: 30) == nil && environment.isAway)
    environment.configure(enabled: true, scene: stallScene)
    let interval = environment.endAway(now: 40)
    #expect(interval?.start == 10 && interval?.end == 30 && interval?.scene == stallScene)
    #expect(!environment.isAway)
}

@Test func stallEnvironmentDropsMicrophoneSessionsCrossingExclusionOrThirtyMinutes() {
    var environment = PersonalEnvironment()
    environment.configure(enabled: true, scene: stallScene)
    #expect(environment.observeMicrophone(running: true, now: 0) == nil)
    environment.configure(enabled: true, scene: nil)
    environment.configure(enabled: true, scene: stallScene)
    #expect(environment.observeMicrophone(running: false, now: 60) == nil)
    _ = environment.observeMicrophone(running: true, now: 100)
    #expect(environment.observeMicrophone(running: false, now: 1900)?.end == 1900)
    _ = environment.observeMicrophone(running: true, now: 2000)
    #expect(environment.observeMicrophone(running: false, now: 3800.001) == nil)
}

@Test func stallEnvironmentDisableAndForgettingCannotResurrectOldSessions() {
    var environment = PersonalEnvironment()
    environment.configure(enabled: true, scene: stallScene)
    _ = environment.beginAway(now: 1)
    _ = environment.observeMicrophone(running: true, now: 1)
    environment.configure(enabled: false, scene: nil)
    environment.configure(enabled: true, scene: stallScene)
    #expect(environment.endAway(now: 2) == nil)
    #expect(environment.observeMicrophone(running: false, now: 2) == nil)
    _ = environment.beginAway(now: 3)
    _ = environment.observeMicrophone(running: true, now: 3)
    environment.forget()
    environment.configure(enabled: true, scene: stallScene)
    #expect(environment.endAway(now: 4) == nil && environment.observeMicrophone(running: false, now: 4) == nil)
}

@Test func stallEnvironmentCanDeferBothLockEventsWhenLoginWindowActivatedFirst() {
    var environment = PersonalEnvironment()
    environment.configure(enabled: true, scene: stallScene)
    environment.configure(enabled: true, scene: nil)
    #expect(environment.beginAway(now: 10, usingPreviousScene: true) == nil)
    #expect(environment.endAway(now: 30) == nil)
    environment.configure(enabled: true, scene: stallScene)
    let interval = environment.endAway(now: 40)
    #expect(interval?.start == 10 && interval?.end == 30 && interval?.scene == stallScene)
    #expect(interval?.beginRecorded == false)
}

@Test func stallThinkingLabelRequiresReconversionOrEvidenceOfTheSameSentence() {
    #expect(PersonalStall.action(.selectNextCandidate, composing: true, knownContinuation: true, convertedBefore: true) == .other)
    #expect(PersonalStall.action(.selectPrevCandidate, composing: true, knownContinuation: true, convertedBefore: true) == .other)
    #expect(PersonalStall.action(.enterCandidateSelectionMode, composing: true, knownContinuation: true, convertedBefore: false) == .other)
    #expect(PersonalStall.action(.enterCandidateSelectionMode, composing: true, knownContinuation: true, convertedBefore: true) == .reconvert)
    #expect(PersonalStall.action(.appendToMarkedText("a"), composing: false, knownContinuation: false, convertedBefore: false) == .typing)
    #expect(PersonalStall.action(.appendToMarkedText("a"), composing: false, knownContinuation: true, convertedBefore: false) == .continuation)
}

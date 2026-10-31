import Foundation
import Testing
@testable import Core

@Test func assistanceTabsSliceOneSentenceIncludingItsClosingQuoteAndShiftTakesAll() {
    let text = "「最初です。」次です！最後です"
    #expect(AssistanceVerbs.chunk(text, all: false).text == "「最初です。」")
    #expect(AssistanceVerbs.chunk(text, all: false).remaining == "次です！最後です")
    #expect(AssistanceVerbs.chunk(text, all: true).text == text)
    #expect(AssistanceVerbs.chunk("3.14です\n次", all: false).text == "3.14です\n")
    #expect(AssistanceVerbs.firstSentence("句点がない断片") == "句点がない断片")
}
@Test func assistanceUndoAndVerbsRequireTheVisibleStateAndExactSuffix() {
    #expect(AssistanceVerbs.canUndo(chunk: "入れた塊", left: "前の文入れた塊", elapsed: 2))
    #expect(!AssistanceVerbs.canUndo(chunk: "入れた塊", left: "別の文", elapsed: 1))
    #expect(!AssistanceVerbs.canUndo(chunk: "入れた塊", left: "入れた塊", elapsed: 2.001))
    #expect(!AssistanceVerbs.canUndo(chunk: "入れた塊", left: nil, elapsed: 1))
    #expect(!AssistanceVerbs.canSummon(helpVisible: false, marked: false))
    #expect(AssistanceVerbs.canSummon(helpVisible: false, marked: true))
    #expect(!AssistanceVerbs.canDismiss(helpVisible: true, composing: true))
    #expect(AssistanceVerbs.canDismiss(helpVisible: true, composing: false))
    #expect(AssistanceVerbs.choice(number: 1, count: 3, marked: false, choicesVisible: false) == nil)
    #expect(AssistanceVerbs.choice(number: 3, count: 3, marked: false, choicesVisible: true) == 2)
    #expect(AssistanceVerbs.backspace("一文。二文。", caret: 6, selectionLength: 0)?.text == "一文。二文")
    #expect(AssistanceVerbs.backspace("あ😀い", caret: 3, selectionLength: 0)?.text == "あい")
    #expect(AssistanceVerbs.backspace("最初と最後", caret: 2, selectionLength: 1)?.text == "最初最後")
    #expect(AssistanceVerbs.backspace("本文", caret: 0, selectionLength: 0) == nil)
}
@Test func assistanceStagingKeepsShortAndChromiumInsertionsImmediateAndRemembersFailures() {
    #expect(!AssistanceVerbs.shouldStage(String(repeating: "あ", count: 12), app: "test"))
    #expect(AssistanceVerbs.shouldStage(String(repeating: "あ", count: 13), app: "test"))
    #expect(!AssistanceVerbs.shouldStage(String(repeating: "あ", count: 13), app: "com.google.Chrome"))
    #expect(!AssistanceVerbs.shouldStage(String(repeating: "あ", count: 13), app: "test", failedApps: ["test"]))
}
@Test func tabOwnerObservesOnlyTheNextGrowthInTheSameSceneWithoutCrossingFields() {
    var tracker = AssistanceVerbs.TabTracker()
    tracker.passed(scene: "app|line|new|-", left: "本文")
    #expect({ tracker.observe(scene: "app|line|new|-", left: "本文追加") }())
    #expect({ !tracker.observe(scene: "app|line|new|-", left: "本文さらに") }())
    tracker.passed(scene: "app|line|new|-", left: "本文")
    #expect({ !tracker.observe(scene: "app2|line|new|-", left: "本文追加") }())
    tracker.passed(scene: "app|line|new|-", left: "本文")
    #expect({ !tracker.observe(scene: "app|line|new|-", left: "本文\n") }())
    tracker.passed(scene: "app|line|new|-", left: "本文"); tracker.reset()
    #expect({ !tracker.observe(scene: "app|line|new|-", left: "本文追加") }())
    tracker.passed(scene: "app|line|new|-", left: String(repeating: "前", count: 100))
    #expect({ tracker.observe(scene: "app|line|new|-", left: String(repeating: "前", count: 98) + "補完") }())
    tracker.passed(scene: "app|line|new|-", left: String(repeating: "前", count: 40))
    #expect({ tracker.observe(scene: "app|line|new|-", left: String(repeating: "前", count: 38) + "補完") }())
}

@Test @MainActor func tabOwnerNeedsTwoObservationsAndUsesExistingReactionDeletionAndExport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersonalStore(url: directory.appendingPathComponent("fixture.sqlite"))
    let learner = PersonalLearner(storeURL: nil); learner.attachStoreForTesting(store)
    let scene = PersonalScene(app: "test.tab-owner", shape: .line, mode: .new, reply: false)
    learner.recordTabOwner(scene: scene)
    #expect(!learner.tabOwnedByApplication(scene: scene))
    learner.recordTabOwner(scene: scene)
    #expect(learner.tabOwnedByApplication(scene: scene))
    learner.flush()
    let file = try learner.export(to: directory.appendingPathComponent("export.jsonl"))
    #expect(try String(contentsOf: file, encoding: .utf8).contains("tab_owner"))
    learner.forgetApp(scene.app); learner.flush()
    #expect(!learner.tabOwnedByApplication(scene: scene))
    let stale = Date(timeIntervalSinceNow: -Double(max(1, Config.PersonalLearningRetentionDays().value) + 1) * 86400)
    learner.recordTabOwner(scene: scene, now: stale); learner.recordTabOwner(scene: scene, now: stale)
    learner.recordTabOwner(scene: scene)
    if Config.PersonalLearningRetentionDays().value > 0 { #expect(!learner.tabOwnedByApplication(scene: scene)) }
    learner.recordTabOwner(scene: scene); learner.recordTabOwner(scene: scene)
    learner.deleteAll(); learner.flush()
    #expect(!learner.tabOwnedByApplication(scene: scene))
    try await Task.sleep(for: .milliseconds(30)); learner.flush()
}

@Test func tabTakesALeadingNewlineTogetherWithTheNextSentence() {
    // 先頭が改行の続きで、Tab で改行だけが入って本文が入らないように見えないこと
    #expect(AssistanceVerbs.chunk("\nどうゆう感じにすればいいのかわからない", all: false).text == "\nどうゆう感じにすればいいのかわからない")
    #expect(AssistanceVerbs.chunk("\n\n次の段落です。その次。", all: false) == ("\n\n次の段落です。", "その次。"))
    #expect(AssistanceVerbs.inlineContinuation("\nどうすればいいかわからない", left: "こういうことやりたいけど", singleLine: false) == "どうすればいいかわからない")
    #expect(AssistanceVerbs.inlineContinuation("\n次の段落です。", left: "一行目\n二行目。", singleLine: false) == "\n次の段落です。")
    #expect(AssistanceVerbs.inlineContinuation("\n次です。", left: "一行目\n二行目。", singleLine: true) == "次です。")
    #expect(AssistanceVerbs.inlineContinuation("続きです。", left: "前", singleLine: true) == "続きです。")
}

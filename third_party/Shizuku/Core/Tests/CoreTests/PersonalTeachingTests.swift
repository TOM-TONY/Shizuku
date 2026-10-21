import Foundation
import Testing
@testable import Core

@Test func teachingUsesWholeNonsecretSentencesAndNeverSilentlyTruncates() {
    #expect(PersonalTeaching.sentences("最初です。次です！") == ["最初です。", "次です！"])
    #expect(PersonalTeaching.sentences("token=sk-dummy-test-key-not-a-real-secret-0000") == nil)
    #expect(PersonalTeaching.sentences(String(repeating: "あ", count: 121)) == nil)
    #expect(PersonalTeaching.sentences(String(repeating: "例です。", count: 21)) == nil)
    #expect(PersonalTeaching.sentences("") == nil)
}

@Test @MainActor func taughtExamplesHaveTheirOwnOriginQuotaUndoAndStorageLifecycles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersonalStore(url: directory.appendingPathComponent("personal.sqlite"))
    let learner = PersonalLearner(storeURL: nil); learner.attachStoreForTesting(store)
    let scene = PersonalScene(app: "editor", shape: .line, mode: .new, reply: false)
    let other = PersonalScene(app: "mail", shape: .line, mode: .new, reply: false)
    let now = Date()
    let first = learner.teach("会議の資料を確認します。", scene: scene, now: now)
    #expect(first.count == 1)
    #expect(learner.corpus.sentences.first?.origin == 3)
    #expect(PersonalQuotes.candidates(corpus: learner.corpus, scene: scene, context: "会議").isEmpty)
    #expect(learner.corpus.retrieve(query: "会議", scene: scene, excluding: "", limit: 1).first?.origin == 3)
    #expect(learner.undoTeaching(token: "wrong", now: now) == 0)
    #expect(learner.undoTeaching(token: try #require(first.token), now: now.addingTimeInterval(10)) == 1)
    #expect(learner.corpus.sentences.isEmpty)
    for index in 0..<20 { #expect(learner.teach("手本\(index)です。", scene: scene, now: now).count == 1) }
    #expect(learner.teach("二十一件目。", scene: scene, now: now).count == 0)
    let last = learner.teach("別の欄の手本。", scene: other, now: now)
    #expect(last.count == 1)
    #expect(learner.undoTeaching(token: try #require(last.token), now: now.addingTimeInterval(10.001)) == 0)
    learner.flush()
    #expect(try store.scalarInt("SELECT COUNT(*) FROM taught WHERE origin=3") == 21)
    #expect(try store.scalarInt("SELECT COUNT(*) FROM commits") == 0)
    #expect(try store.scalarInt("SELECT COUNT(*) FROM lexicon") == 0)
    #expect(learner.teachingSummary().contains("21 文"))
    #expect(try PersonalTeaching.read(store: store).count == 21)
    let reloaded = PersonalLearner(storeURL: store.url); reloaded.prepare()
    for _ in 0..<200 where !reloaded.teachingSummary().contains("21 文") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(reloaded.teachingSummary().contains("21 文"))
    #expect(reloaded.corpus.sentences.count == 21 && reloaded.corpus.sentences.allSatisfy { $0.origin == 3 })
    let export = try learner.export(to: directory.appendingPathComponent("export.jsonl"))
    #expect(try String(contentsOf: export, encoding: .utf8).contains("\"table\":\"taught\""))
    let snapshot = directory.appendingPathComponent("snapshot.sqlite")
    try store.snapshot(to: snapshot)
    #expect(try LabSnapshot.readCommits(url: snapshot).isEmpty)
    _ = try LabSnapshot.readUpperBoundAuxiliary(url: snapshot)
    learner.forgetApp(scene.app); learner.flush()
    #expect(try store.scalarInt("SELECT COUNT(*) FROM taught") == 1)
    #expect(learner.corpus.sentences.allSatisfy { $0.app == other.app })
    try store.execute("UPDATE taught SET ts=0")
    try PersonalLearner.pruneExpired(store: store, now: now)
    #expect(try store.scalarInt("SELECT COUNT(*) FROM taught") == 0)
    learner.deleteAll(); learner.flush()
    #expect(learner.teachingSummary() == "教えた手本: 0 文")
    #expect(try store.scalarInt("SELECT COUNT(*) FROM taught") == 0)
    try await Task.sleep(for: .milliseconds(30)); learner.flush()
}

import Foundation
import SQLite3
import Testing
@testable import Core

private struct OriginStore {
    let directory: URL
    let store: PersonalStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try PersonalStore(url: directory.appendingPathComponent("personal.sqlite"))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func insert(_ id: Int64, ts: Double, kind: String = "enter", text: String = "甲乙丙丁戊己", origin: Int) throws {
        try store.execute("INSERT INTO commits(id,ts,scene,app,kind,surface,origin) VALUES(?,?,'editor|line|new|-','editor',?,?,?)",
                          [.int(id), .double(ts), .text(kind), .text(text), .int(Int64(origin))])
    }
}

@Test func originKindsAndEditingConditionsKeepOnlyTheSpecifiedCases() {
    for kind in ["completion", "idle", "skeleton", "ai", "rewrite"] { #expect(PersonalOrigin.initial(kind: kind) == 1) }
    for kind in ["selection", "enter", "transform", "kana"] { #expect(PersonalOrigin.initial(kind: kind) == 0) }
    for kind in ["completion", "idle"] {
        #expect(!PersonalOrigin.edited(kind: kind, length: 10, ts: 0, reaction: "completion_kept", n: 10, now: 1))
        #expect(PersonalOrigin.edited(kind: kind, length: 10, ts: 0, reaction: "completion_kept", n: 9, now: 1))
    }
    #expect(!PersonalOrigin.edited(kind: "ai", length: 10, ts: 0, reaction: "completion_kept", n: 0, now: 1))
    #expect(PersonalOrigin.edited(kind: "ai", length: 10, ts: 0, reaction: "bs_after_commit", n: 1, now: 120))
    #expect(!PersonalOrigin.edited(kind: "rewrite", length: 10, ts: 0, reaction: "bs_after_commit", n: 1, now: 120.001))
    #expect(!PersonalOrigin.edited(kind: "ai", length: 10, ts: 0, reaction: "bs_after_commit", n: 0, now: 1))
    #expect(!PersonalOrigin.edited(kind: "idle", length: 10, ts: 2, reaction: "completion_kept", n: -1, now: 1))
}

@Test func originPromotionNeedsEightyPercentOnTwoDistinctDays() {
    let same = [(ts: 1.0, text: "甲乙丙丁戊庚"), (ts: 2.0, text: "甲乙丙丁戊庚")]
    #expect(!PersonalOrigin.canPromote("甲乙丙丁戊己", authored: same))
    #expect(PersonalOrigin.canPromote("甲乙丙丁戊己", authored: [same[0], (86401, same[1].text)]))
    #expect(!PersonalOrigin.canPromote("甲乙丙丁戊己", authored: [(1, "甲乙丙丁庚辛"), (86401, "甲乙丙丁庚辛")]))
    #expect(!PersonalOrigin.canPromote("甲", authored: [(1, "甲"), (86401, "甲")]))
}

@Test func originPromotionUsesOnlyAuthoredNormalsAndTheNewestTwoHundredCandidates() throws {
    let fixture = try OriginStore(); defer { fixture.remove() }
    for id in 1...201 { try fixture.insert(Int64(id), ts: Double(id), kind: "ai", origin: 1) }
    try fixture.insert(1000, ts: 86401, origin: 0)
    try fixture.insert(1001, ts: 172801, kind: "ai", origin: 0)
    try fixture.insert(1002, ts: 172802, origin: 2)
    #expect(try !PersonalOrigin.promote(store: fixture.store))
    try fixture.insert(1003, ts: 172803, origin: 0)
    #expect(try PersonalOrigin.promote(store: fixture.store))
    #expect(try fixture.store.scalarInt("SELECT origin FROM commits WHERE id=1") == 1)
    #expect(try fixture.store.scalarInt("SELECT COUNT(*) FROM commits WHERE id BETWEEN 2 AND 201 AND origin=2") == 200)
}

@Test func originEditsAreIdempotentAndRetainTheOriginalTimestampAndOpeningDependencies() throws {
    let fixture = try OriginStore(); defer { fixture.remove() }
    try fixture.insert(1, ts: 10, kind: "completion", origin: 1)
    try fixture.insert(2, ts: 20, origin: 0)
    try fixture.store.execute("INSERT INTO openings(ts,scene,app,text,sources) VALUES(20,'editor|line|new|-','editor','甲乙丙丁戊己','[1,2]')")
    #expect(try PersonalOrigin.entries(store: fixture.store).map(\.id) == [2])
    #expect(try PersonalOrigin.openings(store: fixture.store, origins: PersonalOrigin.origins(store: fixture.store)).isEmpty)
    #expect(try PersonalOrigin.acceptEdit(store: fixture.store, id: 1, reaction: "completion_kept", n: 5, now: 30))
    #expect(try !PersonalOrigin.acceptEdit(store: fixture.store, id: 1, reaction: "completion_kept", n: 5, now: 30))
    let rows = try PersonalOrigin.entries(store: fixture.store)
    #expect(rows.map(\.id) == [1, 2] && rows.first?.ts == 10)
    #expect(try PersonalOrigin.openings(store: fixture.store, origins: PersonalOrigin.origins(store: fixture.store)).count == 1)
    #expect(!PersonalOrigin.openingIsMaterial([99], origins: [:]))
    #expect(PersonalOrigin.openingIsMaterial([], origins: [:]))
}

@Test func originMigrationReadsOldSnapshotsWithoutChangingThemAndKeepsWalAndExport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("old.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TABLE commits(id INTEGER PRIMARY KEY,ts REAL,scene TEXT,app TEXT,kind TEXT,reading TEXT,surface TEXT,first TEXT,left TEXT); INSERT INTO commits VALUES(1,1,'editor|line|new|-','editor','enter','カクニン','確認しました。',NULL,'');", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let bytes = try Data(contentsOf: url)
    #expect(try LabSnapshot.readCommits(url: url).first?.origin == 0)
    #expect(try Data(contentsOf: url) == bytes)
    let store = try PersonalStore(url: url)
    #expect(try store.scalarInt("SELECT origin FROM commits WHERE id=1") == 0)
    var journal = ""
    try store.query("PRAGMA journal_mode") { journal = $0.text(0) ?? "" }
    #expect(journal == "wal")
    let snapshot = directory.appendingPathComponent("snapshot.sqlite")
    try store.snapshot(to: snapshot)
    #expect(try LabSnapshot.readCommits(url: snapshot).count == 1)
    #expect(try LabSnapshot.readCommits(url: snapshot).first?.origin == 0)
    #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
}

@Test func originLabMaterialAndOldCodableRecordsShareTheSameRule() throws {
    let scene = "editor|line|new|-"
    let own = LabCommit(ts: 1, scene: scene, kind: "enter", reading: "カクニン", surface: "確認しました。", first: nil, left: nil)
    var model = own; model.ts = 2; model.kind = "ai"; model.origin = 1; model.surface = "モデルの回答です。"
    #expect(!LabMagic.eligible(model) && LabMagic.eligible(own))
    let train = LabTrainView([own, model], split: LabSplit(split: 10))
    #expect(LabAnalystData(train: train, topics: [], vectors: [:]).rows(scope: "*") == [own])
    let learner = LabReplay.primedLearner(train)
    #expect(learner.corpus.sentences.map(\.text) == [own.surface])
    model.origin = 2
    #expect(LabMagic.eligible(model))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(own)) as? [String: Any])
    object.removeValue(forKey: "origin")
    #expect(try JSONDecoder().decode(LabCommit.self, from: JSONSerialization.data(withJSONObject: object)).origin == 0)
}

@Test func originRecordCommitFiltersCorpusWithoutChangingLexiconExclusions() throws {
    let learner = PersonalLearner(storeURL: nil)
    let scene = try #require(PersonalScene(key: "editor|line|new|-"))
    for kind in ["ai", "idle", "skeleton", "rewrite", "completion"] {
        _ = learner.recordCommit(.init(scene: scene, kind: kind, reading: "カクニン", surface: "確認しました。", defaultSurface: "違う表記"))
    }
    #expect(learner.commitCount == 5 && learner.corpus.sentences.isEmpty)
    #expect(learner.learnedWords().first?.count == 3) // skeleton/rewrite/completionの既存の数え方を保つ。
    _ = learner.recordCommit(.init(scene: scene, kind: "enter", reading: nil, surface: "本人の確認です。", defaultSurface: nil))
    #expect(learner.corpus.sentences.map(\.text) == ["本人の確認です。"])
}

@Test @MainActor func originReactionRebuildsChronologicalMaterialsAndTheirOpenings() async throws {
    let fixture = try OriginStore(); defer { fixture.remove() }
    let learner = PersonalLearner(storeURL: nil)
    learner.attachStoreForTesting(fixture.store)
    let scene = try #require(PersonalScene(key: "editor|line|new|-"))
    let model = try #require(learner.recordCommit(.init(scene: scene, kind: "completion", reading: nil,
        surface: "最初の提案です。", defaultSurface: nil), now: Date(timeIntervalSince1970: 1000)))
    _ = learner.recordCommit(.init(scene: scene, kind: "enter", reading: nil,
        surface: "本人の確認です。", defaultSurface: nil), now: Date(timeIntervalSince1970: 1100))
    learner.flush()
    try fixture.store.execute("INSERT INTO openings(ts,scene,app,text,sources) VALUES(1000,?,'editor','最初の提案です。',?)",
                              [.text(scene.key), .text("[\(model)]")])
    learner.recordReaction(kind: "bs_after_commit", scene: scene, commitID: model, n: 1, now: Date(timeIntervalSince1970: 1110))
    learner.flush()
    for _ in 0..<100 where learner.corpus.sentences.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(learner.corpus.sentences.map(\.text) == ["最初の提案です。", "本人の確認です。"])
    #expect(learner.corpus.sentences.map(\.ts) == [1000, 1100])
    #expect(learner.openingTallies[scene.baseKey]?["最初の提案です。"] == 1)
    let export = try learner.export(to: fixture.directory.appendingPathComponent("export.jsonl"))
    let rows = try String(contentsOf: export, encoding: .utf8).split(separator: "\n").map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    let commits = rows.filter { $0["table"] as? String == "commits" }
    #expect(commits.count == 2 && commits.allSatisfy { $0["origin"] as? String == "0" })
}

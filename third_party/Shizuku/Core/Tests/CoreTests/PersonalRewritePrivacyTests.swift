import Foundation
import Testing
@testable import Core

private func rewritePrivacyStore() throws -> (URL, PersonalStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (directory, try PersonalStore(url: directory.appendingPathComponent("personal.sqlite")))
}

@Test func rewriteKeysNormalizeKanaAndWhitespaceAndDependOnTheStoreSalt() {
    let a = PersonalRewritePrivacy.key("りょう かい\n", salt: "one")
    #expect(a == PersonalRewritePrivacy.key("リョウカイ", salt: "one"))
    #expect(a != PersonalRewritePrivacy.key("リョウカイ", salt: "two"))
    #expect(a.count == 64 && a.allSatisfy { $0.isHexDigit })
    #expect(PersonalRewritePrivacy.normalized("了解しました") == "了解シマシタ")
}

@Test func rewriteMigrationIsAtomicIdempotentAndScrubsOnlyLinkedLeft() throws {
    let (directory, store) = try rewritePrivacyStore(); defer { try? FileManager.default.removeItem(at: directory) }
    let deleted = "とりけしごく"
    try store.execute("DELETE FROM meta WHERE key LIKE 'rewrite.%'")
    for id: Int64 in [1, 2] {
        try store.execute("INSERT INTO commits(id,ts,scene,app,kind,surface,left) VALUES(?,1,'editor|line|new|-','editor','enter','新しい語句',?)",
                          [.int(id), .text("前文" + deleted)])
    }
    try store.execute("INSERT INTO rewrites(ts,scene,app,commit_id,deleted,written) VALUES(1,'editor|line|new|-','editor',1,?,'訂正語句')", [.text(deleted)])
    try store.execute("INSERT INTO reactions(ts,kind,a) VALUES(1,'rewrite_ignored',?)", [.text(deleted)])
    let migrated = try PersonalStore(url: store.url)
    let hash = PersonalRewritePrivacy.key(deleted, salt: migrated.rewriteSalt)
    #expect(try PersonalRewritePrivacy.meta(PersonalRewritePrivacy.migratedRowsKey, store: migrated) == "1")
    #expect(try PersonalRewritePrivacy.meta(PersonalRewritePrivacy.scrubbedLeftKey, store: migrated) == "1")
    var keys: [String] = []
    try migrated.query("SELECT deleted FROM rewrites UNION ALL SELECT a FROM reactions") { keys.append($0.text(0) ?? "") }
    #expect(keys == [hash, hash])
    var lefts: [String] = []
    try migrated.query("SELECT left FROM commits ORDER BY id") { lefts.append($0.text(0) ?? "") }
    #expect(lefts == ["前文" + String(repeating: "∗", count: deleted.count), "前文" + deleted])
    let again = try PersonalStore(url: store.url)
    #expect(again.rewriteSalt == migrated.rewriteSalt)
    var after = ""
    try again.query("SELECT deleted FROM rewrites") { after = $0.text(0) ?? "" }
    #expect(after == hash)
}

@Test func rewriteScrubbingMatchesNormalizedSubstringsAndKeepsOtherCharacters() {
    let hashes: Set<String> = [PersonalRewritePrivacy.key("とりけし", salt: "salt")]
    #expect(PersonalRewritePrivacy.scrub("前文トリ ケシ後文", hashes: hashes, salt: "salt") == "前文∗∗∗∗∗後文")
    #expect(PersonalRewritePrivacy.scrub("前文別の文字後文", hashes: hashes, salt: "salt") == "前文別の文字後文")
}

@Test func rewriteLongAndFourDigitDeletedAreNeverRecorded() {
    for deleted in [String(repeating: "あ", count: 21), "番号1234です", "番号１２３４です", "番号١٢٣٤です"] {
        #expect(!PersonalRewrite.isWorthRecording(deleted: deleted, written: "訂正語句"))
    }
    #expect(PersonalRewrite.isWorthRecording(deleted: String(repeating: "あ", count: 20), written: "訂正語句"))
    #expect(PersonalRewrite.isWorthRecording(deleted: "番号123です", written: "訂正語句"))
}

@Test func rewriteHashedLookupKeepsSuggestionsByteIdenticalWithoutAnIgnoreCountGate() throws {
    let scene = try #require(PersonalScene(key: "editor|line|new|-"))
    let learner = PersonalLearner(storeURL: nil)
    let deleted = "了解しました", written = "承知しました"
    for _ in 0..<3 { learner.recordRewrite(scene: scene, deleted: deleted, written: written, writtenReading: "ショウチシマシタ") }
    let tallies: [String: PersonalRewrite.Tally] = [written: .init(count: 3, reading: "ショウチシマシタ")]
    for ignores in 0...2 {
        let before = PersonalRewrite.suggestion(deleted: deleted, tallies: tallies, ignores: ignores, repeats: 3, currentReading: "リョウカイシマシタ")
        let after = learner.rewriteSuggestion(scene: scene, firstCandidate: deleted, reading: "リョウカイシマシタ", repeats: 3)
        #expect(before.map { Data($0.utf8) } == after.map { Data($0.utf8) })
        #expect(learner.rewriteReading(scene: scene, deleted: deleted, written: written) == "ショウチシマシタ")
        learner.recordRewriteOutcome(scene: scene, deleted: deleted, written: written, accepted: false)
    }
    #expect(learner.rewriteTallies.values.allSatisfy { !$0.keys.contains(deleted) })
}

@Test func rewriteExportSnapshotAndDeleteAllNeverExposeDeletedFields() throws {
    let (directory, store) = try rewritePrivacyStore(); defer { try? FileManager.default.removeItem(at: directory) }
    let learner = PersonalLearner(storeURL: nil); learner.attachStoreForTesting(store)
    let scene = try #require(PersonalScene(key: "editor|line|new|-"))
    let deleted = "とりけしたごく"
    learner.recordRewrite(scene: scene, deleted: deleted, written: "訂正語句", writtenReading: "テイセイゴク")
    learner.recordRewriteOutcome(scene: scene, deleted: deleted, written: "訂正語句", accepted: false)
    _ = learner.recordCommit(.init(scene: scene, kind: "enter", reading: nil, surface: "記録する文です。", defaultSurface: nil,
                                  leftContext: "前文" + deleted))
    learner.flush()
    let export = try learner.export(to: directory.appendingPathComponent("export.jsonl"))
    #expect(try !String(contentsOf: export, encoding: .utf8).contains(deleted))
    let snapshot = directory.appendingPathComponent("snapshot.sqlite")
    try store.snapshot(to: snapshot)
    let rows = try LabSnapshot.readCommits(url: snapshot)
    #expect(rows.count == 1 && rows[0].left == "前文" + String(repeating: "∗", count: deleted.count))
    _ = try LabSnapshot.readUpperBoundAuxiliary(url: snapshot)
    #expect(learner.rewriteCount == 1)
    let salt = store.rewriteSalt
    learner.deleteAll(); learner.flush()
    #expect(store.rewriteSalt != salt)
    #expect(try store.scalarInt("SELECT COUNT(*) FROM rewrites") == 0)
    #expect(try PersonalRewritePrivacy.meta(PersonalRewritePrivacy.saltKey, store: store) == store.rewriteSalt)
}

@Test @MainActor func rewriteLegacyRowsReloadWithByteIdenticalSuggestionsAfterMigration() async throws {
    let (directory, store) = try rewritePrivacyStore(); defer { try? FileManager.default.removeItem(at: directory) }
    let scene = try #require(PersonalScene(key: "editor|line|new|-"))
    let deleted = "了解しました", written = "承知しました"
    let ts = Date().timeIntervalSince1970
    try store.execute("DELETE FROM meta WHERE key LIKE 'rewrite.%'")
    for _ in 0..<3 {
        try store.execute("INSERT INTO rewrites(ts,scene,app,deleted,written,written_reading) VALUES(?,?,?,?,?,?)",
            [.double(ts), .text(scene.key), .text(scene.app), .text(deleted), .text(written), .text("ショウチシマシタ")])
    }
    try store.execute("INSERT INTO reactions(ts,scene,app,kind,a) VALUES(?,?,?,'rewrite_ignored',?)",
                      [.double(ts), .text(scene.key), .text(scene.app), .text(deleted)])
    let expected = PersonalRewrite.suggestion(deleted: deleted, tallies: [written: .init(count: 3, reading: "ショウチシマシタ")],
        ignores: 1, repeats: 3, currentReading: "リョウカイシマシタ")
    let learner = PersonalLearner(storeURL: store.url)
    learner.prepare()
    for _ in 0..<200 where learner.rewriteCount != 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(learner.rewriteCount == 3)
    let actual = learner.rewriteSuggestion(scene: scene, firstCandidate: deleted, reading: "リョウカイシマシタ", repeats: 3)
    #expect(actual.map { Data($0.utf8) } == expected.map { Data($0.utf8) })
    #expect(learner.rewriteReading(scene: scene, deleted: deleted, written: written) == "ショウチシマシタ")
    #expect(learner.rewritePrivacySummary().contains("ハッシュ 3/3"))
    learner.flush()
}

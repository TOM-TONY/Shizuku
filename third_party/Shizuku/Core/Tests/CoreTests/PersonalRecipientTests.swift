import Foundation
import Testing
@testable import Core

private func recipientScene(_ rank: PersonalRecipient.Rank? = nil, place: String? = "example.test") -> PersonalScene {
    PersonalScene(app: "com.example.recipient", shape: .line, mode: .new, reply: false, place: place, recipient: rank)
}

@Test func recipientKeysKeepLegacyFourAndFivePartsAndReserveTheSixthForRank() throws {
    for place: String? in [nil, "example.test", "r1"] {
        let scene = recipientScene(place: place)
        let expected = "com.example.recipient|line|new|-" + (place.map { "|" + $0 } ?? "")
        #expect(Data(scene.key.utf8) == Data(expected.utf8))
        #expect(PersonalScene(key: expected) == scene)
        #expect(PersonalScene(key: expected)?.recipient == nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let old: [String: Any] = ["app": scene.app, "shape": "line", "mode": "new", "reply": false]
            .merging(place.map { ["place": $0] } ?? [:]) { _, new in new }
        let bytes = try JSONSerialization.data(withJSONObject: old, options: .sortedKeys)
        #expect(try encoder.encode(scene) == bytes)
        #expect(try JSONDecoder().decode(PersonalScene.self, from: bytes) == scene)
    }
    for rank in PersonalRecipient.Rank.allCases {
        for place: String? in [nil, "example.test"] {
            let scene = recipientScene(rank, place: place)
            #expect(scene.key == "com.example.recipient|line|new|-|" + (place ?? "") + "|" + rank.rawValue)
            #expect(PersonalScene(key: scene.key) == scene)
            #expect(PersonalScene.baseKey(of: scene.key) == scene.baseKey)
        }
    }
    #expect(PersonalScene(key: "app|line|new|-||r9") == nil)
    #expect(PersonalScene(key: "app|line|new|-|a|r1|extra") == nil)
}

@Test func recipientFallbackHasRankThenPlaceThenBaseAppAndGlobal() {
    let fine = recipientScene(.r3), place = recipientScene(), base = recipientScene(place: nil)
    #expect(fine.sceneKeys == [fine.key, place.key, base.key])
    #expect(fine.levelKeys == [fine.key, place.key, base.key, "app:" + fine.app, "global"])
    #expect(recipientScene(.r2, place: nil).sceneKeys == [base.key + "||r2", base.key])
    #expect(PersonalTuner.levelKeys(for: fine) == PersonalStyleProfile.levels(fine))
    #expect(PersonalScene.contains(fine.key, at: place.key))
    #expect(!PersonalScene.contains(fine.key, at: recipientScene(.r1).key))
    #expect(!PersonalScene.contains(fine.key, at: place.key + "2"))
}

@Test func recipientRulesUseOnlyTheFirstSixtyCharactersAndGivePoliteCuesPriority() {
    for text in ["宛名様\n確認のお願い。", "開発部御中", "拝啓", "お世話になっております。", "恐れ入りますが", "確認いたします。"] {
        #expect(PersonalRecipient.infer(prefix: text) == .r3)
    }
    for text in ["宛名さん\n", "お疲れ様です。", "これは確認です。", "確認します。"] {
        #expect(PersonalRecipient.infer(prefix: text) == .r2)
    }
    for text in ["宛名ちゃん\n", "宛名くん\n", "確認だ。", "確認である。", "そうじゃん。", "そうだよ。", "そうかな。", "😊"] {
        #expect(PersonalRecipient.infer(prefix: text) == .r1)
    }
    #expect(PersonalRecipient.infer(prefix: "様子を記録。たくさん。123") == nil)
    #expect(PersonalRecipient.infer(prefix: "前回と同様。そうだよ。") == .r1)
    #expect(PersonalRecipient.infer(prefix: "😊。確認いたします。") == .r3)
    #expect(PersonalRecipient.infer(prefix: String(repeating: "あ", count: 60) + "御中") == nil)
}

@Test func recipientStateDecidesOnceAtTwoSentencesOrSixtyCharactersAndKeepsUndeterminedKeys() {
    var state = PersonalRecipient.State()
    state.observe(mode: .new, left: "宛名様。", enabled: true, startedEmpty: true)
    #expect(!state.decided && state.rank == nil)
    state.observe(mode: .new, left: "宛名様。確認。", enabled: true, startedEmpty: true)
    #expect(state.decided && state.rank == .r3)
    state.observe(mode: .new, left: "別の相手だよ。確認だ。", enabled: true, startedEmpty: true)
    #expect(state.rank == .r3)
    state.reset()
    state.observe(mode: .new, left: String(repeating: "あ", count: 59), enabled: true, startedEmpty: true)
    #expect(!state.decided)
    state.observe(mode: .new, left: String(repeating: "あ", count: 60), enabled: true, startedEmpty: true)
    #expect(state.decided && state.rank == nil)
    state.observe(mode: .new, left: "御中。確認。", enabled: true, startedEmpty: true)
    #expect(state.rank == nil)
    #expect(recipientScene(state.rank).key == recipientScene().key)
}

@Test func recipientStateDoesNotInferForExistingFieldsOrWhenLearningIsOff() {
    var state = PersonalRecipient.State()
    state.observe(mode: .append, left: "宛名様。確認。", enabled: true, startedEmpty: true)
    state.observe(mode: .new, left: "宛名様。確認。", enabled: true, startedEmpty: true)
    #expect(!state.decided && state.rank == nil)
    state.reset()
    state.observe(mode: .new, left: "宛名様。確認。", enabled: false)
    #expect(!state.decided && state.rank == nil)
    #expect(recipientScene(state.rank).key == recipientScene().key)
    state.observe(mode: .new, left: "宛名様！！", enabled: true, startedEmpty: true)
    #expect(!state.decided) // 続く記号を2文とは数えない。
    state.reset()
    state.observe(mode: .new, left: nil, enabled: true, startedEmpty: false)
    state.observe(mode: .append, left: "宛名様。確認。", enabled: true, startedEmpty: false)
    #expect(!state.decided && state.rank == nil) // 観測不能を空欄と扱わない。
}

@Test func recipientRefinementKeepsTheUnfinishedSentenceInLiveAndReplayedCorpus() {
    let corpus = PersonalCorpus()
    let prefix = "拝啓" + String(repeating: "あ", count: 58)
    corpus.add(scene: recipientScene(), text: prefix, ts: 1)
    corpus.add(scene: recipientScene(.r3), text: "確認します。", ts: 2)
    #expect(corpus.sentences.count == 1)
    #expect(corpus.sentences.first?.text == prefix + "確認します。")
    #expect(corpus.sentences.first?.scene == recipientScene(.r3).key)
    let commits = [LabCommit(ts: 1, scene: recipientScene().key, kind: "enter", reading: nil, surface: prefix, first: nil, left: nil),
                   LabCommit(ts: 2, scene: recipientScene(.r3).key, kind: "enter", reading: nil, surface: "確認します。", first: nil, left: nil)]
    let replay = LabReplay.primedLearner(LabTrainView(commits, split: .init(split: 10)))
    #expect(replay.corpus.sentences == corpus.sentences)
}

@Test func recipientStateAndSerializedSceneNeverRetainNamesOrAddresseeText() throws {
    var a = PersonalRecipient.State(), b = PersonalRecipient.State()
    a.observe(mode: .new, left: "架空の宛名甲様。確認。", enabled: true, startedEmpty: true)
    b.observe(mode: .new, left: "別の宛名乙様。報告。", enabled: true, startedEmpty: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let bytes = try encoder.encode(recipientScene(a.rank))
    #expect(bytes == (try encoder.encode(recipientScene(b.rank))))
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["recipient"] as? String == "r3")
    #expect(Set(object.keys) == ["app", "shape", "mode", "reply", "place", "recipient"])
    #expect(!String(decoding: bytes, as: UTF8.self).contains("宛名"))
    #expect(Mirror(reflecting: a).children.allSatisfy { !($0.value is String) })
}

@Test func recipientCorpusAndLexiconUseTheSharedAncestorOrder() {
    let learner = PersonalLearner(storeURL: nil)
    for i in 0..<2 {
        learner.recordCommit(.init(scene: recipientScene(.r3), kind: "enter", reading: "シズク", surface: "雫", defaultSurface: "しずく"), now: Date(timeIntervalSince1970: 1000 + Double(i)))
        learner.recordCommit(.init(scene: recipientScene(.r1), kind: "enter", reading: "シズク", surface: "滴", defaultSurface: "しずく"), now: Date(timeIntervalSince1970: 1010 + Double(i)))
    }
    #expect(learner.preferredEntry(forReading: "シズク", scene: recipientScene(.r3))?.surface == "雫")
    #expect(learner.preferredEntry(forReading: "シズク", scene: recipientScene(.r1))?.surface == "滴")
    let corpus = PersonalCorpus()
    corpus.add(scene: recipientScene(.r3), text: "議事録の内容を確認いたします。", ts: 1)
    corpus.add(scene: recipientScene(.r1), text: "議事録の内容を確認するよ。", ts: 2)
    #expect(corpus.retrieve(query: "議事録", scene: recipientScene(.r3), excluding: "").count == 2) // 1件だけなら既存と同じく後退。
    corpus.add(scene: recipientScene(.r3), text: "議事録の議題も確認いたします。", ts: 3)
    #expect(corpus.retrieve(query: "議事録", scene: recipientScene(.r3), excluding: "", limit: 1).first?.scene == recipientScene(.r3).key)
    #expect(corpus.retrieve(query: "議事録", scene: recipientScene(.r2), excluding: "").count == 3)
}

@Test func recipientOpeningsRewritesPausesAndProfilesAggregateThroughThePlace() throws {
    let learner = PersonalLearner(storeURL: nil)
    for i in 0..<5 { learner.recordOpening(scene: recipientScene(i % 2 == 0 ? .r1 : .r3), text: "お疲れさまです。") }
    #expect(learner.openingSuggestion(scene: recipientScene(.r2)) == "お疲れさまです。")
    #expect(learner.openingSuggestion(scene: recipientScene()) == "お疲れさまです。")
    for rank in [PersonalRecipient.Rank.r1, .r3, .r1] {
        learner.recordRewrite(scene: recipientScene(rank), deleted: "了解しました", written: "承知しました", writtenReading: "ショウチシマシタ")
    }
    #expect(learner.rewriteSuggestion(scene: recipientScene(.r2), firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == "承知しました")
    learner.recordPause(scene: recipientScene(.r3), seconds: 3)
    for key in recipientScene(.r3).levelKeys { #expect(learner.pauseHistograms[key]?.total == 1) }
    var profile = PersonalStyleProfile()
    for _ in 0..<10 { profile.observe(scene: recipientScene(.r1), text: "確認!確認してください。") }
    for _ in 0..<10 { profile.observe(scene: recipientScene(.r3), text: "確認！ご確認ください。") }
    #expect(try #require(profile.plans()[recipientScene(.r3).key]).apply("確認!確認してください。") == "確認！ご確認ください。")
    let tuner = PersonalTuner()
    tuner.attach(settings: [recipientScene().key: [.idleDelay: .init(value: 4)]], persist: { _,_,_ in })
    #expect(tuner.value(.idleDelay, scene: recipientScene(.r3)) == 4)
}

import Testing
@testable import Core

@Test func quotesUsePersonalSentencesOnlyWithinTheAppAndNeverRepeatExistingContext() {
    let corpus = PersonalCorpus()
    let scene = PersonalScene(app: "test", shape: .line, mode: .new, reply: false)
    corpus.add(scene: scene, text: "会議の資料を確認します。", ts: 1)
    corpus.add(scene: scene, text: "会議の日程を確認します。", ts: 2)
    corpus.add(scene: .init(app: "other", shape: .line, mode: .new, reply: false), text: "会議の秘密の別アプリ。", ts: 3)
    corpus.addTaught(scene: scene, text: "会議で教えた他人の文。", ts: 4, id: "taught")
    let found = PersonalQuotes.candidates(corpus: corpus, scene: scene, context: "会議の資料を確認します。次の会議")
    #expect(found == ["会議の日程を確認します。"])
    let empty = PersonalQuotes.candidates(corpus: corpus, scene: scene, context: "")
    #expect(empty == ["会議の日程を確認します。", "会議の資料を確認します。"])
}

@Test func quotesCapLiteralTextAtFiftyAndUseTheExistingBm25Order() {
    let corpus = PersonalCorpus()
    let scene = PersonalScene(app: "test", shape: .line, mode: .new, reply: false)
    for i in 0..<5 { corpus.add(scene: scene, text: "会議\(i)の" + String(repeating: "資料", count: 30) + "。", ts: Double(i)) }
    let found = PersonalQuotes.candidates(corpus: corpus, scene: scene, context: "会議の資料")
    #expect(found.count == 3)
    #expect(found.allSatisfy { $0.count <= 50 })
    #expect(found.first?.hasPrefix("会議4") == true)
    let remaining = PersonalQuotes.candidates(corpus: corpus, scene: scene, context: found.joined() + "会議の資料")
    #expect(remaining.count == 2 && remaining.allSatisfy { !found.contains($0) })
}

@Test func retentionUsesTwoMinuteObservationAndSeparatesMissingContextFromDeletion() {
    let check = AssistanceRetention(text: "前に書いた文です。", started: 100)
    #expect(check.retained(left: "前に書いた文です。続けて書く", complete: false, now: 219) == nil)
    #expect(check.retained(left: "前に書いた文です。続けて書く", complete: false, now: 220) == 9)
    #expect(check.retained(left: nil, complete: false, now: 220) == nil)
    #expect(check.retained(left: "全く別", complete: false, now: 220) == nil)
    #expect(check.retained(left: "全く別", complete: true, now: 220) == 0)
    #expect(check.retained(left: "前に書いた文です。", complete: true, now: 701) == nil)
}

import Foundation
import Testing
@testable import Core

// MARK: - 場面

@Test func personalSceneClassifiesFieldShapeAndMode() throws {
    func scene(length: Int?, empty: Bool = false, left: String = "", right: String = "") -> PersonalScene? {
        PersonalScene.classify(
            observation: .init(bundleID: "com.example.chat", documentLength: length, startedEmpty: empty),
            leftContext: left,
            rightContext: right
        )
    }
    // 空の 1 行の欄に書き始めた
    #expect(scene(length: 0)?.key == "com.example.chat|line|new|-")
    // 空から書き始めた欄に追記している間は新規のまま
    #expect(scene(length: 12, empty: true, left: "今日の会議は")?.mode == .new)
    // 既にある文章の末尾に書き足す
    #expect(scene(length: 12, left: "今日の会議は")?.mode == .append)
    // カーソルの右に文字がある（編集）
    #expect(scene(length: 20, left: "今日の", right: "会議は延期")?.mode == .edit)
    // 改行がある・長い
    #expect(scene(length: 40, left: "お疲れさまです。\n本日の")?.shape == .short)
    #expect(scene(length: 3000, left: "第1章")?.shape == .doc)
    #expect(scene(length: nil, left: String(repeating: "あ\n", count: 12))?.shape == .doc)
    // 文書の長さを返さないアプリは、運ばれた文脈の長さで判断する
    #expect(scene(length: nil, left: String(repeating: "あ", count: 300))?.shape == .short)
    // アプリがわからなければ場面なし
    #expect(PersonalScene.classify(observation: .init(bundleID: nil), leftContext: "", rightContext: "") == nil)
    // キーの文字列から戻せる
    let s = try #require(scene(length: 0))
    #expect(PersonalScene(key: s.key) == s)
}

@Test func personalSceneDetectsReplies() {
    #expect(PersonalScene.looksLikeReply(left: "", right: "\n\n> 明日の件ですが"))
    #expect(PersonalScene.looksLikeReply(left: "", right: "2026年10月12日 10:00 山田 <y@example.com>:\nが書きました："))
    #expect(PersonalScene.looksLikeReply(left: "On Mon, Oct 12, 2026 at 10:00 Taro wrote:", right: ""))
    #expect(!PersonalScene.looksLikeReply(left: "明日は 3>2 で", right: ""))
    #expect(!PersonalScene.looksLikeReply(left: "お疲れさまです。", right: ""))
}

// MARK: - プライバシー

@Test func personalPrivacyFilters() {
    // ターミナルは AI の道具への入力を学ぶため記録する。画面の文脈の対象からは外したまま
    #expect(!PersonalPrivacy.isExcluded(app: "com.apple.Terminal"))
    #expect(PersonalPrivacy.terminalApps.contains("com.apple.Terminal"))
    #expect(PersonalPrivacy.isExcluded(app: "com.1password.1password"))
    #expect(PersonalPrivacy.looksSecret("パスワードは hunter2xyz789abc です"))
    #expect(PersonalPrivacy.looksSecret("sk-dummy-test-key-not-a-real-secret-0000"))
    #expect(!PersonalPrivacy.looksSecret("ChatGPT で調べた"))
    #expect(!PersonalPrivacy.looksSecret("今日は 2026 年 10 月"))
    #expect(PersonalPrivacy.scrub("鍵は AKIA1234567890ABCD です") == "鍵は ∗ です")
    #expect(PersonalPrivacy.isWithoutJapanese("ChatGPT"))
    #expect(PersonalPrivacy.isWithoutJapanese("1,234.5"))
    #expect(!PersonalPrivacy.isWithoutJapanese("申請"))
    #expect(!PersonalPrivacy.isWithoutJapanese("シズク"))
}

// MARK: - 自動辞書

private let chatLine = PersonalScene(app: "com.example.chat", shape: .line, mode: .new, reply: false)
private let chatDoc = PersonalScene(app: "com.example.chat", shape: .doc, mode: .append, reply: false)
private let mailDoc = PersonalScene(app: "com.example.mail", shape: .doc, mode: .new, reply: true)

private func commit(
    _ learner: PersonalLearner, _ scene: PersonalScene, reading: String, surface: String, defaultSurface: String?, at t: Double
) {
    learner.recordCommit(
        .init(scene: scene, kind: "selection", reading: reading, surface: surface, defaultSurface: defaultSurface),
        now: Date(timeIntervalSince1970: t)
    )
}

@Test func autoDictionaryRegistersAfterTwoNonDefaultCommitsInTheSameScene() {
    let learner = PersonalLearner(storeURL: nil)
    commit(learner, chatLine, reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1000)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine) == nil)
    commit(learner, chatLine, reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1001)
    let entry = learner.preferredEntry(forReading: "シズク", scene: chatLine)
    #expect(entry?.surface == "雫")
    #expect(entry?.level == .scene)
    // 同じアプリの別の場面では、アプリの段（3 回）にはまだ届かない
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatDoc) == nil)
    // 第 1 候補のまま確定したものは数えない（記録のない読み）
    commit(learner, chatLine, reading: "シンセイ", surface: "申請", defaultSurface: "申請", at: 1002)
    commit(learner, chatLine, reading: "シンセイ", surface: "申請", defaultSurface: "申請", at: 1003)
    #expect(learner.preferredEntry(forReading: "シンセイ", scene: chatLine) == nil)
}

@Test func autoDictionaryBacksOffToAppAndGlobal() {
    let learner = PersonalLearner(storeURL: nil)
    // 同じアプリの 2 つの場面で計 3 回 → アプリの段で登録（記録のない第 3 の場面で使われる）
    commit(learner, chatLine, reading: "トモナリ", surface: "友成", defaultSurface: "共鳴り", at: 1000)
    commit(learner, chatDoc, reading: "トモナリ", surface: "友成", defaultSurface: "共鳴り", at: 1001)
    let chatShort = PersonalScene(app: "com.example.chat", shape: .short, mode: .new, reply: false)
    #expect(learner.preferredEntry(forReading: "トモナリ", scene: chatShort) == nil)
    commit(learner, chatDoc, reading: "トモナリ", surface: "友成", defaultSurface: "共鳴り", at: 1002)
    #expect(learner.preferredEntry(forReading: "トモナリ", scene: chatShort)?.level == .app)
    // 別のアプリでは全体の段（4 回）が必要
    #expect(learner.preferredEntry(forReading: "トモナリ", scene: mailDoc) == nil)
    commit(learner, chatLine, reading: "トモナリ", surface: "友成", defaultSurface: "共鳴り", at: 1003)
    #expect(learner.preferredEntry(forReading: "トモナリ", scene: mailDoc)?.level == .global)
}

@Test func autoDictionaryFollowsTheLatestChoiceInTheMostSpecificScene() {
    let learner = PersonalLearner(storeURL: nil)
    commit(learner, chatLine, reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1000)
    commit(learner, chatLine, reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1001)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine)?.surface == "雫")
    // その場面で、先頭に出した「雫」ではなく別の表記を選んだ → 先頭に置くのをやめる（1 回では登録しない）
    commit(learner, chatLine, reading: "シズク", surface: "しずく", defaultSurface: "雫", at: 1002)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine) == nil)
    // 続けて選べば、得票が 2 番目の 3 倍を超えたところで、その表記を覚える（交互に選ぶ表記は先頭に置かない）
    commit(learner, chatLine, reading: "シズク", surface: "しずく", defaultSurface: "しずく", at: 1003)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine) == nil)
    commit(learner, chatLine, reading: "シズク", surface: "しずく", defaultSurface: "しずく", at: 1004)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine)?.surface == "しずく")
}

@Test func autoDictionaryIgnoresShortReadingsKanaCommitsAndExcludedApps() {
    let learner = PersonalLearner(storeURL: nil)
    // 1 文字の読み
    commit(learner, chatLine, reading: "ハ", surface: "葉", defaultSurface: "は", at: 1000)
    commit(learner, chatLine, reading: "ハ", surface: "葉", defaultSurface: "は", at: 1001)
    #expect(learner.preferredEntry(forReading: "ハ", scene: chatLine) == nil)
    // 2 文字の読みは先頭に置く
    commit(learner, chatLine, reading: "カミ", surface: "神", defaultSurface: "紙", at: 1002)
    commit(learner, chatLine, reading: "カミ", surface: "神", defaultSurface: "紙", at: 1003)
    #expect(learner.preferredEntry(forReading: "カミ", scene: chatLine)?.surface == "神")
    // 変換せずに確定したもの
    for t in 0..<3 {
        learner.recordCommit(
            .init(scene: chatLine, kind: "kana", reading: "アリガトウ", surface: "ありがとう", defaultSurface: "有難う"),
            now: Date(timeIntervalSince1970: 1010 + Double(t))
        )
    }
    #expect(learner.preferredEntry(forReading: "アリガトウ", scene: chatLine) == nil)
    // 除外したアプリ・英字だけの確定は記録しない
    let passwords = PersonalScene(app: "com.1password.1password", shape: .line, mode: .new, reply: false)
    #expect(learner.recordCommit(.init(scene: passwords, kind: "selection", reading: "シズク", surface: "雫", defaultSurface: "しずく")) == nil)
    #expect(learner.recordCommit(.init(scene: chatLine, kind: "kana", reading: "CHATGPT", surface: "ChatGPT", defaultSurface: nil)) == nil)
}

@Test func forgettingALearnedWordRemovesItFromEveryScene() throws {
    let learner = PersonalLearner(storeURL: nil)
    commit(learner, chatLine, reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1000)
    commit(learner, chatLine, reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1001)
    let word = try #require(learner.learnedWords().first)
    #expect(word.surface == "雫")
    #expect(word.scene == chatLine)
    learner.forgetWord(id: word.id)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine) == nil)
    #expect(learner.learnedWords().isEmpty)
}

// MARK: - 記録（SQLite）

@Test func personalStoreRoundTripAndExport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ime-personal-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let url = directory.appendingPathComponent("personal.sqlite")
    let store = try PersonalStore(url: url)
    try store.queue.sync {
        try store.execute(
            "INSERT INTO lexicon(scene, app, reading, surface, lcid, rcid, mid, count, nondefault, last) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(chatLine.key), .text(chatLine.app), .text("シズク"), .text("雫"), .int(1), .int(1), .int(1), .int(2), .int(2), .double(1000)]
        )
        var rows: [(String, Int64)] = []
        try store.query("SELECT surface, count FROM lexicon") { row in
            rows.append((row.text(0) ?? "", row.int(1)))
        }
        #expect(rows.count == 1)
        #expect(rows.first?.0 == "雫")
        #expect(rows.first?.1 == 2)
        #expect(try store.scalarInt("SELECT COUNT(*) FROM commits") == 0)
    }
}

// MARK: - 文脈つき選択学習

@Test func contextLevelSelectionFollowsTheChoiceInTheSameContext() {
    let learner = PersonalLearner(storeURL: nil)
    // 「経費の」の後で「しんせい」を、第 1 候補（新生）を退けて「申請」にした
    learner.recordCommit(
        .init(scene: chatLine, kind: "selection", reading: "シンセイ", surface: "申請", defaultSurface: "新生", leftContext: "今月の経費の"),
        now: Date(timeIntervalSince1970: 1000)
    )
    #expect(learner.preferredEntry(forReading: "シンセイ", scene: chatLine, leftContext: "来月の経費の")?.surface == "申請")
    #expect(learner.preferredEntry(forReading: "シンセイ", scene: chatLine, leftContext: "来月の経費の")?.level == .context)
    // 別の文脈では使わない（場面の段は 2 回必要）
    #expect(learner.preferredEntry(forReading: "シンセイ", scene: chatLine, leftContext: "これは") == nil)
    // 同じ文脈で次に第 1 候補のまま確定したら、その文脈では先頭に置かない
    learner.recordCommit(
        .init(scene: chatLine, kind: "enter", reading: "シンセイ", surface: "新生", defaultSurface: "新生", leftContext: "これは経費の"),
        now: Date(timeIntervalSince1970: 1001)
    )
    #expect(learner.preferredEntry(forReading: "シンセイ", scene: chatLine, leftContext: "経費の") == nil)
    #expect(PersonalLearner.contextKey("") == "^")
    #expect(PersonalLearner.contextKey("今日は 晴れ ") == "晴れ")
}

// MARK: - 打ち間違いの癖

@Test func typoPairsAreCountedAndOutcomesAdjustThresholds() {
    let learner = PersonalLearner(storeURL: nil)
    learner.recordTypoPair(typed: "i", fixed: "u", reading: nil, scene: nil)
    #expect(learner.frequentTypoPairs().isEmpty)
    for _ in 0..<4 {
        learner.recordTypoPair(typed: "i", fixed: "u", reading: nil, scene: nil)
    }
    #expect(learner.frequentTypoPairs() == ["iu": 5])
    // 2 文字以上の打ち直しは 1 文字の組には数えない
    learner.recordTypoPair(typed: "ka", fixed: "ki", reading: nil, scene: nil)
    #expect(learner.frequentTypoPairs().count == 1)
    learner.recordTypoOutcome(target: "アリガトウ", accepted: true)
    #expect(learner.typoMarginAdjustment(forTarget: "アリガトウ") == -0.5)
    learner.recordTypoOutcome(target: "キズク", accepted: false)
    learner.recordTypoOutcome(target: "キズク", accepted: false)
    #expect(learner.typoMarginAdjustment(forTarget: "キズク") == 2.0)
    #expect(learner.typoMarginAdjustment(forTarget: "ミズ") == 0)
}

// MARK: - 本人の文の手本

@Test func personalCorpusRetrievesSimilarSentencesFromTheSameScene() {
    let corpus = PersonalCorpus()
    var t = 1000.0
    func add(_ scene: PersonalScene, _ text: String) {
        t += 10
        corpus.add(scene: scene, text: text, ts: t)
    }
    add(chatLine, "経費の申請を")
    add(chatLine, "お願いします。")
    add(chatLine, "交通費の申請は今週中にお願いします。")
    add(chatLine, "了解です！")
    add(mailDoc, "経費の精算について、ご確認ください。")
    #expect(corpus.sentences.count == 4)
    #expect(corpus.sentences.first?.text == "経費の申請をお願いします。")
    let found = corpus.retrieve(query: "出張の経費の申請", scene: chatLine, excluding: "")
    #expect(found.first?.text.contains("申請") == true)
    #expect(found.allSatisfy { $0.scene == chatLine.key })
    // 文脈にすでにある文は手本にしない
    let excluded = corpus.retrieve(query: "経費の申請", scene: chatLine, excluding: "経費の申請をお願いします。")
    #expect(!excluded.contains { $0.text == "経費の申請をお願いします。" })
    let prefix = corpus.completionPrefix(style: .retrieve, scene: chatLine, query: "経費の申請", context: "")
    #expect(prefix.hasSuffix("\n\n"))
    #expect(corpus.completionPrefix(style: .none, scene: chatLine, query: "経費", context: "").isEmpty)
    // 60 秒以上あいた句は別の文
    corpus.add(scene: chatLine, text: "あとで", ts: t + 100)
    corpus.add(scene: chatLine, text: "確認します。", ts: t + 300)
    #expect(corpus.sentences.last?.text == "確認します。")
}

@Test func kanaVariantOutcomesAdjustTheThresholdPerReading() {
    #expect(PersonalLearner.isKanaVariant(typed: "ツズキ", committed: "ツヅキ"))
    #expect(PersonalLearner.isKanaVariant(typed: "チジム", committed: "チヂム"))
    #expect(!PersonalLearner.isKanaVariant(typed: "ツズキ", committed: "ツズキ"))
    #expect(!PersonalLearner.isKanaVariant(typed: "キズク", committed: "キヅク" + "ヨ"))
    let learner = PersonalLearner(storeURL: nil)
    learner.recordKanaVariantOutcome(reading: "ツズキ", accepted: true, scene: nil)
    #expect(learner.kanaVariantMarginAdjustment(forReading: "ツズキ") == -0.5)
    // 置き換えを退けた読み（築く→気付く）では使わない
    learner.recordKanaVariantOutcome(reading: "キズク", accepted: false, scene: nil)
    #expect(learner.kanaVariantMarginAdjustment(forReading: "キズク") >= 100)
    #expect(learner.kanaVariantMarginAdjustment(forReading: "ミズ") == 0)
}

// MARK: - 自己調整

private func pieces(_ items: [(String, Float)]) -> [NextTextCompletionEngine.Piece] {
    items.map { .init(text: $0.0, logProb: $0.1) }
}

@Test func tunerPicksTheThresholdThatSavesMostWithoutLosingAccuracy() {
    // 正解の続き「お願いします。」。自信の低い 2 トークン目まで出せば当たる位置が多く、低い自信で外れる位置は少ない
    var outcomes: [PersonalTuner.ReplayOutcome] = []
    for _ in 0..<30 {
        outcomes.append(.init(levels: ["s"], pieces: pieces([("お願い", -0.2), ("します", -0.85), ("。", -0.1)]), gold: "お願いします。"))
    }
    for _ in 0..<5 {
        outcomes.append(.init(levels: ["s"], pieces: pieces([("よろしく", -0.95), ("です", -0.3)]), gold: "了解です"))
    }
    let suggestion: ([NextTextCompletionEngine.Piece], Float) -> String? = { pieces, threshold in
        var text = ""
        for piece in pieces where piece.logProb >= threshold {
            text += piece.text
        }
        let firstLow = pieces.firstIndex { $0.logProb < threshold }
        if let firstLow {
            text = pieces[..<firstLow].map(\.text).joined()
        }
        return text.count >= 2 ? text : nil
    }
    let scores = PersonalTuner.scores(outcomes, suggestion: suggestion)
    #expect(scores.map(\.threshold) == [-1.0, -0.9, -0.8, -0.7, -0.6, -0.5])
    // −0.9 なら「お願いします。」を出せて節約が増え、精度は −0.7（お願い）と同じ 100%（「よろしく」は −0.95 で出ない）
    #expect(PersonalTuner.bestThreshold(scores) == -0.9)
    let tuner = PersonalTuner()
    #expect(tuner.applyReplay(outcomes, baseline: { _ in (0.5, 0.2) }, now: 1e6, suggestion: suggestion) == ["s"])
    #expect(tuner.settings["s"]?[.completionThreshold]?.value == -0.9)
    #expect(tuner.settings["s"]?[.completionThreshold]?.isOnTrial == true)
    // 数が足りない段では選ばない
    #expect(PersonalTuner().applyReplay(Array(outcomes.prefix(10)), baseline: { _ in nil }, now: 1000, suggestion: suggestion).isEmpty)
}

@Test func tunerKeepsTheDefaultUnlessTheGainIsClear() {
    func score(_ threshold: Double, saved: Int) -> PersonalTuner.ThresholdScore {
        .init(threshold: threshold, shown: 40, correct: 20, savedCharacters: saved, samples: 200)
    }
    // 既定 100 文字に対して 104 文字（4%）: 偶然の差とみなして既定のまま
    #expect(PersonalTuner.bestThreshold([score(-0.8, saved: 104), score(-0.7, saved: 100), score(-0.6, saved: 90)]) == -0.7)
    // 112 文字（12%、12 文字）なら動かす
    #expect(PersonalTuner.bestThreshold([score(-0.8, saved: 112), score(-0.7, saved: 100), score(-0.6, saved: 90)]) == -0.8)
    // 割合は大きくても 5 文字未満なら動かさない
    #expect(PersonalTuner.bestThreshold([score(-0.8, saved: 14), score(-0.7, saved: 10)]) == -0.7)
}

@Test func tunerRevertsATrialThatGotWorseAndFreezesThatDirection() {
    let tuner = PersonalTuner()
    let day = 86400.0
    // 放置の続きがほとんど使われない → 待ち時間を長くする（試行）
    #expect(tuner.adjustByAcceptance(.idleDelay, level: "s", shown: 40, accepted: 4, now: 10 * day))
    #expect(tuner.settings["s"]?[.idleDelay]?.value == 3.5)
    // 試行中は動かさない
    #expect(!tuner.adjustByAcceptance(.idleDelay, level: "s", shown: 40, accepted: 1, now: 12 * day))
    // 変えた後、まだ数が足りなければ判定しない
    #expect(tuner.evaluateTrial(.idleDelay, level: "s", events: 10, acceptance: 0, saved: nil, now: 11 * day) == .pending)
    // 変えた後の採用率が 5 ポイント以上下がった → 元に戻し、同じ向き（長くする）は 7 日間動かさない
    #expect(tuner.evaluateTrial(.idleDelay, level: "s", events: 30, acceptance: 0.0, saved: nil, now: 11 * day) == .reverted)
    #expect(tuner.settings["s"]?[.idleDelay]?.value == 3.0)
    #expect(!tuner.adjustByAcceptance(.idleDelay, level: "s", shown: 40, accepted: 4, now: 13 * day))
    #expect(tuner.adjustByAcceptance(.idleDelay, level: "s", shown: 40, accepted: 4, now: 19 * day))
    // 良くなった試行は残す
    #expect(tuner.evaluateTrial(.idleDelay, level: "s", events: 30, acceptance: 0.2, saved: nil, now: 20 * day) == .kept)
    #expect(tuner.settings["s"]?[.idleDelay]?.value == 3.5)
    #expect(tuner.settings["s"]?[.idleDelay]?.isOnTrial == false)
}

@Test func tunerStaysWithinTheEvaluatedRanges() {
    let tuner = PersonalTuner()
    var now = 0.0
    for _ in 0..<20 {
        now += 2 * 86400
        tuner.adjustByAcceptance(.idleDelay, level: "s", shown: 40, accepted: 0, now: now)
        tuner.evaluateTrial(.idleDelay, level: "s", events: 40, acceptance: 0.1, saved: nil, now: now)
    }
    #expect(tuner.settings["s"]?[.idleDelay]?.value == 6.0)
    for _ in 0..<20 {
        now += 2 * 86400
        tuner.adjustByAcceptance(.typoMarginOffset, level: "s", shown: 40, accepted: 40, now: now, low: 0.3, high: 0.6)
        tuner.evaluateTrial(.typoMarginOffset, level: "s", events: 40, acceptance: 1, saved: nil, now: now)
    }
    #expect(tuner.settings["s"]?[.typoMarginOffset]?.value == -0.5)
    // 数が少なければ動かさない
    #expect(!PersonalTuner().adjustByAcceptance(.idleDelay, level: "s", shown: 5, accepted: 0, now: 1))
    // 調整を元に戻す
    tuner.reset()
    #expect(tuner.settings.isEmpty)
    #expect(tuner.value(.idleDelay, scene: chatLine) == nil)
}

@Test func tunerLooksUpSceneThenAppThenGlobal() {
    let tuner = PersonalTuner()
    _ = tuner.propose(.completionThreshold, value: -0.9, level: "global", baseline: nil, now: 1e6)
    #expect(tuner.value(.completionThreshold, scene: chatLine) == -0.9)
    _ = tuner.propose(.completionThreshold, value: -0.6, level: "app:" + chatLine.app, baseline: nil, now: 1e6)
    #expect(tuner.value(.completionThreshold, scene: chatLine) == -0.6)
    #expect(tuner.value(.completionThreshold, scene: mailDoc) == -0.9)
}

@Test func replayRunsOnlyOnACPowerWhenIdleAndNotInPowerSaving() {
    let ok = PersonalTuner.Conditions(
        onACPower: true, lowPowerMode: false, powerSavingModel: false, completionEnabled: true,
        secondsSinceLastKey: 900, secondsSinceLastReplay: 7 * 3600, newCommits: 80
    )
    #expect(PersonalTuner.mayReplay(ok))
    var c = ok
    c.onACPower = false
    #expect(!PersonalTuner.mayReplay(c))
    c = ok
    c.lowPowerMode = true
    #expect(!PersonalTuner.mayReplay(c))
    c = ok
    c.powerSavingModel = true
    #expect(!PersonalTuner.mayReplay(c))
    c = ok
    c.secondsSinceLastKey = 60
    #expect(!PersonalTuner.mayReplay(c))
    c = ok
    c.secondsSinceLastReplay = 3600
    #expect(!PersonalTuner.mayReplay(c))
    c = ok
    c.newCommits = 10
    #expect(!PersonalTuner.mayReplay(c))
}

@Test func replayFollowsThePickedCompletionModelNotTheOldPowerSavingFlag() throws {
    // 続き予測のモデルのフォルダ（E2B・E4B）を一時フォルダに作る
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-models-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["gemma4-e2b-ane", "gemma4-e4b-ane"] {
        let model = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: model.appendingPathComponent("lm_head.mlmodelc"), withIntermediateDirectories: true)
        for file in ["meta.json", "host.json", "tokenizer.bin"] {
            try Data("{}".utf8).write(to: model.appendingPathComponent(file))
        }
    }
    func mayReplay(picked: String, oldFlag: Bool) -> Bool {
        let model = NextTextCompletionEngine.modelDirectoryURL(powerSaving: oldFlag, selected: picked, in: directory)
        return PersonalTuner.mayReplay(.init(
            onACPower: true, lowPowerMode: false, powerSavingModel: PersonalTuner.isPowerSavingModel(model), completionEnabled: true,
            secondsSinceLastKey: 900, secondsSinceLastReplay: 7 * 3600, newCommits: 80
        ))
    }
    // 画面で E2B を選んでいれば、電源につながっていても再生しない
    #expect(!mayReplay(picked: "gemma4-e2b-ane", oldFlag: false))
    // 画面で E4B を選んでいれば、古い省電力のスイッチがオンのままでも再生する
    #expect(mayReplay(picked: "gemma4-e4b-ane", oldFlag: true))
    // 選んでいない（または選んだものが使えない）ときは、実際に読み込む方で決まる
    #expect(!mayReplay(picked: "", oldFlag: true))
    #expect(mayReplay(picked: "", oldFlag: false))
}

@Test func replaySamplesCutPhrasesAndUseNeighboringCommits() {
    let rows: [(scene: String, ts: Double, surface: String)] = [
        (chatLine.key, 100, "お世話になっております。"),
        (chatLine.key, 110, "経費の申請を"),
        (chatLine.key, 120, "お願いします。"),
        (chatLine.key, 900, "別件です。"),
    ]
    let samples = PersonalLearner.replaySamples(from: rows, limit: 10)
    #expect(samples.count == 4)
    let middle = samples.first { $0.ts == 110 }!
    #expect(middle.context.hasPrefix("お世話になっております。経費"))
    #expect(middle.gold.hasSuffix("お願いします。"))
    #expect("経費の申請を".hasSuffix(String(middle.gold.dropLast("お願いします。".count))))
    // 10 分以上あいた確定は文脈・続きに入れない
    let last = samples.first { $0.ts == 900 }!
    #expect(!last.context.contains("お願いします"))
}

// MARK: 場面に合わせた入力モード（フェーズ 3）

@Test func inputModePreferredNeedsThreeObservationsAndOwnSwitch() {
    var votes = PersonalInputMode.Votes()
    PersonalInputMode.add(&votes, language: .english, switched: true, now: 1)
    PersonalInputMode.add(&votes, language: .english, switched: false, now: 2)
    #expect(PersonalInputMode.preferred(votes) == nil)
    PersonalInputMode.add(&votes, language: .english, switched: false, now: 3)
    #expect(PersonalInputMode.preferred(votes) == .english)
    // 自分で切り替えたことが一度もなければ（いつもそのモードのまま打っているだけなら）決めない
    var noSwitch = PersonalInputMode.Votes()
    for t in 0..<5 {
        PersonalInputMode.add(&noSwitch, language: .japanese, switched: false, now: Double(t))
    }
    #expect(PersonalInputMode.preferred(noSwitch) == nil)
}

@Test func inputModeStopsAfterOneRevert() {
    var votes = PersonalInputMode.Votes()
    for t in 0..<4 {
        PersonalInputMode.add(&votes, language: .english, switched: true, now: Double(t))
    }
    #expect(PersonalInputMode.preferred(votes) == .english)
    // 切り替わった直後に自分で戻して書いた
    PersonalInputMode.add(&votes, language: .japanese, switched: true, now: 10)
    #expect(PersonalInputMode.preferred(votes) == nil)
}

@Test func inputModeNeverSwitchesWhenToggleIsOff() {
    for preferred in [InputLanguage.english, .japanese, nil] as [InputLanguage?] {
        for current in [InputLanguage.english, .japanese] {
            for typed in [false, true] {
                #expect(PersonalInputMode.switchTarget(enabled: false, preferred: preferred, current: current, typedSinceActivation: typed) == nil)
            }
        }
    }
    #expect(PersonalInputMode.switchTarget(enabled: true, preferred: .english, current: .japanese, typedSinceActivation: false) == .english)
    // 打ち始めた後・同じモード・決まっていないときは切り替えない
    #expect(PersonalInputMode.switchTarget(enabled: true, preferred: .english, current: .japanese, typedSinceActivation: true) == nil)
    #expect(PersonalInputMode.switchTarget(enabled: true, preferred: .english, current: .english, typedSinceActivation: false) == nil)
    #expect(PersonalInputMode.switchTarget(enabled: true, preferred: nil, current: .japanese, typedSinceActivation: false) == nil)
}

@Test func inputModeLearnerKeepsVotesPerAppAndForgets() {
    let learner = PersonalLearner(storeURL: nil)
    for t in 0..<3 {
        learner.recordInputMode(app: "com.tinyspeck.slackmacgap", language: .english, switched: true, now: Date(timeIntervalSince1970: Double(t)))
        // 記録しないアプリ（パスワード管理など）は数えない
        learner.recordInputMode(app: "com.1password.1password", language: .english, switched: true, now: Date(timeIntervalSince1970: Double(t)))
    }
    #expect(learner.preferredInputMode(app: "com.tinyspeck.slackmacgap") == .english)
    #expect(learner.preferredInputMode(app: "com.apple.mail") == nil)
    #expect(learner.preferredInputMode(app: "com.1password.1password") == nil)
    learner.forgetInputMode(app: "com.tinyspeck.slackmacgap")
    #expect(learner.preferredInputMode(app: "com.tinyspeck.slackmacgap") == nil)
}

// MARK: - 打鍵のリズム・言い直し（フェーズ 4）

@Test func rhythmHistogramQuantiles() {
    var histogram = PersonalRhythm.Histogram()
    for _ in 0..<100 {
        PersonalRhythm.add(&histogram, seconds: 1.0, now: 1)
    }
    for _ in 0..<100 {
        PersonalRhythm.add(&histogram, seconds: 4.0, now: 2)
    }
    // 範囲外（キーの連打・席を外した）は数えない
    #expect(!PersonalRhythm.add(&histogram, seconds: 0.01, now: 3))
    #expect(!PersonalRhythm.add(&histogram, seconds: 120, now: 3))
    #expect(histogram.total == 200)
    let p25 = PersonalRhythm.quantile(histogram, 0.25)!
    let p90 = PersonalRhythm.quantile(histogram, 0.9)!
    #expect(abs(p25 - 1.0) < 0.12)
    #expect(abs(p90 - 4.0) < 0.5)
    #expect(PersonalRhythm.quantile(PersonalRhythm.Histogram(), 0.9) == nil)
    // 多くなったら半分にする（割合は保つ）
    for _ in 0..<5000 {
        PersonalRhythm.add(&histogram, seconds: 2.0, now: 4)
    }
    #expect(histogram.total <= 4001)
    #expect(abs(PersonalRhythm.quantile(histogram, 0.5)! - 2.0) < 0.25)
}

@Test func rhythmPausesAreCountedPerLevelAndNotForExcludedApps() {
    let learner = PersonalLearner(storeURL: nil)
    learner.recordPause(scene: chatLine, seconds: 2.0)
    learner.recordPause(scene: chatDoc, seconds: 3.0)
    #expect(learner.pauseHistograms[chatLine.key]?.total == 1)
    #expect(learner.pauseHistograms["app:" + chatLine.app]?.total == 2)
    #expect(learner.pauseHistograms["global"]?.total == 2)
    let passwords = PersonalScene(app: "com.1password.1password", shape: .doc, mode: .append, reply: false)
    learner.recordPause(scene: passwords, seconds: 2.0)
    #expect(learner.pauseHistograms["global"]?.total == 2)
    learner.deleteAll()
    #expect(learner.pauseHistograms.isEmpty)
}

@Test func flushPersistsPausesStillInsideTheBatchWindow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersonalStore(url: directory.appendingPathComponent("personal.sqlite"))
    let learner = PersonalLearner(storeURL: nil)
    learner.attachStoreForTesting(store)
    let now = Date()
    learner.recordPause(scene: chatLine, seconds: 2, now: now)
    learner.flush()
    // Four more pauses arrive before the regular 60-second batch flush.
    for i in 1...4 { learner.recordPause(scene: chatLine, seconds: 3, now: now.addingTimeInterval(Double(i))) }
    func savedTotal() throws -> Int {
        try store.queue.sync {
            var json = ""
            try store.query("SELECT json FROM pauses WHERE level='global'") { json = $0.text(0) ?? "" }
            return try JSONDecoder().decode(PersonalRhythm.Histogram.self, from: Data(json.utf8)).total
        }
    }
    #expect(try savedTotal() == 1)
    #expect(learner.pauseHistograms["global"]?.total == 5)
    learner.flush()
    #expect(try savedTotal() == 5)
    // Repeating a shutdown/paused flush must not add counts or overwrite unrelated levels.
    learner.flush()
    #expect(try savedTotal() == 5)
    let reopened = try PersonalStore(url: directory.appendingPathComponent("personal.sqlite"))
    let persisted = try reopened.queue.sync { try reopened.scalarInt("SELECT COUNT(*) FROM pauses") }
    #expect(persisted == Int64(PersonalTuner.levelKeys(for: chatLine).count))
}

@Test func rewriteDeletedSpanFollowsBackspacesAndChecksTheLeftContext() {
    let after = "お世話になっております。了解しました"
    #expect(PersonalRewrite.deletedSpan(afterCommit: after, backspaces: 6, leftContextNow: "お世話になっております。") == "了解しました")
    // 左文脈が分からなければ、バックスペースの数だけで
    #expect(PersonalRewrite.deletedSpan(afterCommit: after, backspaces: 6, leftContextNow: nil) == "了解しました")
    // 消した残りと左文脈が合わない（カーソルを動かした）
    #expect(PersonalRewrite.deletedSpan(afterCommit: after, backspaces: 6, leftContextNow: "別の文章") == nil)
    // 確定した文より多く消した・消していない
    #expect(PersonalRewrite.deletedSpan(afterCommit: "了解", backspaces: 5, leftContextNow: nil) == nil)
    #expect(PersonalRewrite.deletedSpan(afterCommit: after, backspaces: 0, leftContextNow: nil) == nil)
    #expect(PersonalRewrite.isWorthRecording(deleted: "了解しました", written: "承知しました"))
    #expect(!PersonalRewrite.isWorthRecording(deleted: "了解しました", written: "了解しました"))
    #expect(!PersonalRewrite.isWorthRecording(deleted: " ", written: "承知"))
    #expect(!PersonalRewrite.isWorthRecording(deleted: "了解", written: "sk_live_8f3kD92kfj3K29dkfj39"))
}

// MARK: - 迷いの検知（フェーズ 4）

private func rhythm(_ seconds: [Double], times: Int) -> PersonalRhythm.Histogram {
    var histogram = PersonalRhythm.Histogram()
    for _ in 0..<times {
        for value in seconds {
            PersonalRhythm.add(&histogram, seconds: value, now: 1)
        }
    }
    return histogram
}

@Test func hesitationDelayFallsBackUntilEnoughPausesAndIsClamped() {
    // 199 回では足りない → 使わない
    #expect(PersonalRhythm.personalDelay(histograms: [rhythm([1.0], times: 199)], quantile: 0.9) == nil)
    // 細かい段が足りなければ、次の段
    let delay = PersonalRhythm.personalDelay(histograms: [rhythm([1.0], times: 10), rhythm([0.5, 1.0, 2.0, 2.5, 4.0], times: 60)], quantile: 0.9)!
    #expect(delay > 3.0 && delay < 4.6)
    // 範囲に収める
    #expect(PersonalRhythm.personalDelay(histograms: [rhythm([0.3], times: 300)], quantile: 0.9) == 1.5)
    #expect(PersonalRhythm.personalDelay(histograms: [rhythm([20.0], times: 300)], quantile: 0.9) == 6.0)
}

@Test func hesitationStartsAsATrialAndRevertsWhenAcceptanceDrops() {
    let tuner = PersonalTuner()
    let day = 86400.0
    let pauses = ["app:" + chatLine.app: rhythm([1.0, 2.0, 4.5], times: 100)]
    // 始める前は既定（nil＝本体の 3 秒）
    #expect(tuner.idleDelay(scene: chatLine, pauses: pauses) == nil)
    // 手を止めた回数が足りない段では始めない
    #expect(!tuner.activateRhythm(level: "global", pauses: 150, baselineAcceptance: 0.3, now: 10 * day))
    #expect(tuner.activateRhythm(level: "app:" + chatLine.app, pauses: 300, baselineAcceptance: 0.3, now: 10 * day))
    let delay = tuner.idleDelay(scene: chatLine, pauses: pauses)!
    #expect(delay > 3.5 && delay <= 4.6)
    // 試している間は分位を動かさない
    #expect(!tuner.adjustIdleByAcceptance(level: "app:" + chatLine.app, shown: 40, accepted: 2, now: 11 * day))
    // 採用率が 30% → 20% に下がった → 元の秒数に戻し、7 日間は試さない
    #expect(tuner.evaluateTrial(.idleRhythm, level: "app:" + chatLine.app, events: 30, acceptance: 0.2, saved: nil, now: 12 * day) == .reverted)
    #expect(tuner.idleDelay(scene: chatLine, pauses: pauses) == nil)
    #expect(!tuner.activateRhythm(level: "app:" + chatLine.app, pauses: 300, baselineAcceptance: 0.3, now: 13 * day))
    #expect(tuner.activateRhythm(level: "app:" + chatLine.app, pauses: 300, baselineAcceptance: 0.3, now: 20 * day))
    // 下がらなければ続ける。その後は採用率で分位を動かす（低ければ上げる＝出しにくく）
    #expect(tuner.evaluateTrial(.idleRhythm, level: "app:" + chatLine.app, events: 30, acceptance: 0.32, saved: nil, now: 21 * day) == .kept)
    #expect(tuner.adjustIdleByAcceptance(level: "app:" + chatLine.app, shown: 40, accepted: 2, now: 22 * day))
    #expect(abs((tuner.settings["app:" + chatLine.app]?[.idleQuantile]?.value ?? 0) - 0.95) < 1e-9)
    #expect(tuner.settings["app:" + chatLine.app]?[.idleDelay] == nil)
    // リズムを使っていない段は、これまでどおり秒数を動かす
    #expect(tuner.adjustIdleByAcceptance(level: "global", shown: 40, accepted: 2, now: 22 * day))
    #expect(tuner.settings["global"]?[.idleDelay]?.value == 3.5)
}

// MARK: - 言い直し（フェーズ 4）

@Test func rewriteSuggestionNeedsThreeRepeatsADifferentReadingAndStopsAfterTwoIgnores() {
    let tallies: [String: PersonalRewrite.Tally] = ["承知しました": .init(count: 3, reading: "ショウチシマシタ")]
    func suggest(_ tallies: [String: PersonalRewrite.Tally], deleted: String = "了解しました", ignores: Int = 0, repeats: Int = 3, reading: String = "りょうかいしました") -> String? {
        PersonalRewrite.suggestion(deleted: deleted, tallies: tallies, ignores: ignores, repeats: repeats, currentReading: reading)
    }
    #expect(suggest(tallies) == "承知しました")
    // 2 回ではまだ（自己調整で 2 に下げた場面なら出す）
    #expect(suggest(["承知しました": .init(count: 2, reading: "ショウチシマシタ")]) == nil)
    #expect(suggest(["承知しました": .init(count: 2, reading: "ショウチシマシタ")], repeats: 2) == "承知しました")
    // 少数回の無視では止めない。Serverの共通Wilson門で判定する。
    #expect(suggest(tallies, ignores: 1) == "承知しました")
    #expect(suggest(tallies, ignores: 2) == "承知しました")
    // 同じ読み（表記の選び直し）は選択学習が受け持つ
    #expect(suggest(["了解しました": .init(count: 5, reading: "リョウカイシマシタ")], deleted: "了承しました") == nil)
    #expect(suggest(["諒解しました": .init(count: 5, reading: "リョウカイシマシタ")]) == nil)
    // 読みが分からない・1 文字・書き直しが割れている
    #expect(suggest(["承知しました": .init(count: 5, reading: nil)]) == nil)
    #expect(suggest(["を": .init(count: 5, reading: "ヲ")], deleted: "が", reading: "が") == nil)
    #expect(suggest(["承知しました": .init(count: 3, reading: "ショウチシマシタ"), "かしこまりました": .init(count: 3, reading: "カシコマリマシタ")]) == nil)
}

@Test func rewriteLearnerSuggestsPerSceneAndForgets() {
    let learner = PersonalLearner(storeURL: nil)
    for _ in 0..<3 {
        learner.recordRewrite(scene: chatLine, deleted: "了解しました", written: "承知しました", writtenReading: "ショウチシマシタ")
    }
    #expect(learner.rewriteSuggestion(scene: chatLine, firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == "承知しました")
    // 場面の段だけ（同じアプリの別の場面では出さない）
    #expect(learner.rewriteSuggestion(scene: chatDoc, firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == nil)
    // 同じ語句の打ち直しは数えない
    learner.recordRewrite(scene: chatDoc, deleted: "了解", written: "了解", writtenReading: "リョウカイ")
    #expect(learner.rewriteTallies[chatDoc.key] == nil)
    learner.recordRewriteOutcome(scene: chatLine, deleted: "了解しました", written: "承知しました", accepted: true)
    learner.recordRewriteOutcome(scene: chatLine, deleted: "了解しました", written: "承知しました", accepted: false)
    #expect(learner.rewriteSuggestion(scene: chatLine, firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == "承知しました")
    learner.recordRewriteOutcome(scene: chatLine, deleted: "了解しました", written: "承知しました", accepted: false)
    #expect(learner.rewriteSuggestion(scene: chatLine, firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == "承知しました")
    learner.deleteAll()
    #expect(learner.rewriteTallies.isEmpty)
}

@Test func rewriteRepeatsRelaxToTwoOnlyWithHighAcceptanceAndRevert() {
    let tuner = PersonalTuner()
    let day = 86400.0
    #expect(tuner.rewriteRepeats(scene: chatLine) == 3)
    // 出した数が足りない・採用率が 70% 未満・場面の段でない
    #expect(!tuner.relaxRewriteRepeats(level: chatLine.key, shown: 19, accepted: 19, now: 10 * day))
    #expect(!tuner.relaxRewriteRepeats(level: chatLine.key, shown: 30, accepted: 20, now: 10 * day))
    #expect(!tuner.relaxRewriteRepeats(level: "app:" + chatLine.app, shown: 30, accepted: 30, now: 10 * day))
    #expect(tuner.relaxRewriteRepeats(level: chatLine.key, shown: 20, accepted: 15, now: 10 * day))
    #expect(tuner.rewriteRepeats(scene: chatLine) == 2)
    #expect(tuner.rewriteRepeats(scene: chatDoc) == 3)
    // 2 回にした後、採用率が 75% → 60% に下がった → 3 に戻し、7 日間は試さない
    #expect(tuner.evaluateTrial(.rewriteRepeats, level: chatLine.key, events: 30, acceptance: 0.6, saved: nil, now: 12 * day) == .reverted)
    #expect(tuner.rewriteRepeats(scene: chatLine) == 3)
    #expect(!tuner.relaxRewriteRepeats(level: chatLine.key, shown: 20, accepted: 18, now: 14 * day))
}

// MARK: - アプリごとに記録を消す

@MainActor @Test func forgetAppDeletesOnlyThatAppEverywhereAndLeavesNoTextOnDisk() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ime-forget-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("personal.sqlite")
    let store = try PersonalStore(url: url)
    let learner = PersonalLearner(storeURL: nil)
    learner.attachStoreForTesting(store)
    let now = Date()
    let secret = "ひみつの打ち合わせ議事録です。"
    for (i, scene) in [chatLine, chatLine, mailDoc, mailDoc].enumerated() {
        let surface = scene.app == chatLine.app ? secret : "請求書をお送りします。"
        learner.recordCommit(
            .init(scene: scene, kind: "selection", reading: "シズク", surface: "雫" + surface, defaultSurface: "しずく", leftContext: "^"),
            now: now.addingTimeInterval(Double(i))
        )
        learner.recordReaction(kind: "completion_ignored", scene: scene, a: surface, now: now)
        learner.recordTypoPair(typed: "a", fixed: "s", reading: "サ", scene: scene, now: now)
        learner.recordRewrite(scene: scene, deleted: "了解しました", written: "承知しました", writtenReading: "ショウチシマシタ", now: now)
        learner.recordPause(scene: scene, seconds: 2.0, now: now)
        learner.recordInputMode(app: scene.app, language: .english, switched: true, now: now)
    }
    learner.flushPauses(now: now)
    learner.flush()
    func count(_ table: String, app: String) throws -> Int64 {
        var result: Int64 = 0
        try store.queue.sync {
            result = try store.scalarInt("SELECT COUNT(*) FROM \(table) WHERE app = ?", [.text(app)]) ?? 0
        }
        return result
    }
    let tables = ["commits", "reactions", "typo_pairs", "lexicon", "rewrites", "input_mode"]
    let mailBefore = try tables.map { try count($0, app: mailDoc.app) }
    #expect(try tables.allSatisfy { try count($0, app: chatLine.app) > 0 })
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine)?.surface == "雫" + secret)

    learner.forgetApp(chatLine.app)
    // 記録から消すのは裏のキュー（キー入力の処理を待たせない）。数え直した集計は主スレッドに届く
    learner.flush()
    try await Task.sleep(for: .milliseconds(50))
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine) == nil)

    // そのアプリの行はどの表にも残らず、ほかのアプリは変わらない
    #expect(try tables.allSatisfy { try count($0, app: chatLine.app) == 0 })
    #expect(try tables.map { try count($0, app: mailDoc.app) } == mailBefore)
    var otherRows: [String: Int64] = [:]
    try store.queue.sync {
        otherRows["context_lexicon"] = try store.scalarInt(
            "SELECT COUNT(*) FROM context_lexicon WHERE substr(scene, 1, ?) = ?", [.int(Int64(chatLine.app.count + 1)), .text(chatLine.app + "|")]
        )
        otherRows["pauses"] = try store.scalarInt("SELECT COUNT(*) FROM pauses WHERE level LIKE '%com.example.chat%'")
        otherRows["mailPauses"] = try store.scalarInt("SELECT COUNT(*) FROM pauses WHERE level LIKE '%com.example.mail%'")
    }
    #expect(otherRows["context_lexicon"] == 0)
    #expect(otherRows["pauses"] == 0)
    #expect(otherRows["mailPauses"] == 2)
    // 全体の手を止めた長さは、残ったアプリの分だけ
    #expect(learner.pauseHistograms["global"]?.total == 2)
    #expect(learner.commitCount == 2)
    // 消した文章はファイル（WAL も）に残らない
    for file in [url, URL(fileURLWithPath: url.path + "-wal")] {
        if let data = try? Data(contentsOf: file) {
            #expect(data.range(of: Data(secret.utf8)) == nil)
        }
    }
}

@Test func forgetAppStopsOfferingAnythingLearnedInThatApp() {
    let learner = PersonalLearner(storeURL: nil)
    let now = Date()
    for i in 0..<3 {
        learner.recordCommit(
            .init(scene: chatLine, kind: "selection", reading: "シズク", surface: "雫", defaultSurface: "しずく", leftContext: "今日は"),
            now: now.addingTimeInterval(Double(i))
        )
        learner.recordRewrite(scene: chatLine, deleted: "了解しました", written: "承知しました", writtenReading: "ショウチシマシタ", now: now)
        learner.recordInputMode(app: chatLine.app, language: .english, switched: true, now: now)
        learner.recordCommit(.init(scene: chatLine, kind: "enter", reading: nil, surface: "議事録を共有します。", defaultSurface: nil), now: now)
    }
    learner.recordCommit(.init(scene: mailDoc, kind: "enter", reading: nil, surface: "請求書をお送りします。", defaultSurface: nil), now: now)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine) != nil)
    #expect(learner.rewriteSuggestion(scene: chatLine, firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == "承知しました")
    #expect(learner.preferredInputMode(app: chatLine.app) == .english)
    let generation = learner.forgetGeneration

    learner.forgetApp(chatLine.app)

    #expect(learner.forgetGeneration == generation + 1)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine) == nil)
    #expect(learner.preferredEntry(forReading: "シズク", scene: chatLine, leftContext: "今日は") == nil)
    #expect(learner.rewriteSuggestion(scene: chatLine, firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == nil)
    #expect(learner.preferredInputMode(app: chatLine.app) == nil)
    #expect(!learner.corpus.sentences.contains { $0.app == chatLine.app })
    #expect(!learner.completionPrefix(scene: mailDoc, context: "議事録").contains("議事録を共有"))
    #expect(learner.corpus.sentences.contains { $0.app == mailDoc.app })
}

@Test func testStoreRecordsOnlyProbeAppsAndChangesNothingWithoutIt() {
    // 確かめ用の記録の場所を使っている間は、xpcprobe のアプリだけを記録する
    #expect(PersonalPrivacy.excludedByTestStore(app: "com.tinyspeck.slackmacgap", usingTestStore: true))
    #expect(!PersonalPrivacy.excludedByTestStore(app: "dev.tomonari.xpcprobe.rewrite", usingTestStore: true))
    // 使っていなければ、どのアプリもこれでは除かない（今までどおり）
    #expect(!PersonalPrivacy.excludedByTestStore(app: "com.tinyspeck.slackmacgap", usingTestStore: false))
    #expect(!PersonalPrivacy.excludedByTestStore(app: "dev.tomonari.xpcprobe.rewrite", usingTestStore: false))
    // テストのプロセスには環境変数がない
    #expect(!PersonalLearner.isUsingTestStore)
    #expect(!PersonalPrivacy.isExcluded(app: "com.tinyspeck.slackmacgap"))
}

// MARK: - 文の骨組みの先出し（書き出し、フェーズ 4）

@Test func openingExtractTakesTheFirstSentence() {
    #expect(PersonalOpening.extract("お疲れさまです。経費の件ですが", final: false) == "お疲れさまです。")
    // 文が終わっていなければ、まだ（送信などで終わったらそこまで）
    #expect(PersonalOpening.extract("お疲れさまです", final: false) == nil)
    #expect(PersonalOpening.extract("お疲れさまです", final: true) == "お疲れさまです")
    #expect(PersonalOpening.isIncomplete("お疲れさまです"))
    #expect(!PersonalOpening.isIncomplete("お疲れさまです。"))
    // 短すぎる・長すぎる・秘密らしい
    #expect(PersonalOpening.extract("あ", final: true) == nil)
    #expect(PersonalOpening.extract(String(repeating: "あ", count: 41), final: true) == nil)
    #expect(PersonalOpening.extract("token sk_live_8f3kD92kfj3K29dkfj39", final: true) == nil)
}

@Test func openingSuggestionNeedsFiveOpeningsAFortyPercentShareAndLeavesSilencingToWilson() {
    #expect(PersonalOpening.suggestion(tallies: ["お疲れさまです。": 4], ignores: 0) == nil)
    #expect(PersonalOpening.suggestion(tallies: ["お疲れさまです。": 5], ignores: 0) == "お疲れさまです。")
    #expect(PersonalOpening.suggestion(tallies: ["お疲れさまです。": 2, "了解です。": 2, "はい。": 2], ignores: 0) == nil)
    #expect(PersonalOpening.suggestion(tallies: ["お疲れさまです。": 4, "了解です。": 3, "はい。": 3], ignores: 0) == "お疲れさまです。")
    #expect(PersonalOpening.suggestion(tallies: ["お疲れさまです。": 5], ignores: 2) == "お疲れさまです。")
    #expect(PersonalOpening.suggestion(tallies: ["お疲れさまです。": 5], ignores: 3) == "お疲れさまです。")

    let learner = PersonalLearner(storeURL: nil)
    for _ in 0..<5 {
        learner.recordOpening(scene: chatLine, text: "お疲れさまです。")
    }
    #expect(learner.openingSuggestion(scene: chatLine) == "お疲れさまです。")
    // 場面の段だけ
    #expect(learner.openingSuggestion(scene: chatDoc) == nil)
    for _ in 0..<3 {
        learner.recordOpeningOutcome(scene: chatLine, text: "お疲れさまです。", accepted: false)
    }
    #expect(learner.openingSuggestion(scene: chatLine) == "お疲れさまです。")
    // アプリごとに消すと、書き出しも消える
    for _ in 0..<5 {
        learner.recordOpening(scene: mailDoc, text: "お世話になっております。")
    }
    #expect(learner.openingSuggestion(scene: mailDoc) == "お世話になっております。")
    learner.forgetApp(mailDoc.app)
    #expect(learner.openingSuggestion(scene: mailDoc) == nil)
    #expect(learner.openingTallies[mailDoc.key] == nil)
}

@Test func skeletonIsNotShownWithoutAUsableCaretRect() {
    let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    let window = CGRect(x: 200, y: 100, width: 900, height: 700)
    let caret = CGRect(x: 320, y: 180, width: 1, height: 18)
    #expect(PersonalOpening.isUsableAnchor(caret, screens: screens, clientWindow: window))
    // 0 の矩形・原点・初期化されていない値（Chromium 系の空の欄）
    #expect(!PersonalOpening.isUsableAnchor(.zero, screens: screens, clientWindow: window))
    #expect(!PersonalOpening.isUsableAnchor(CGRect(x: 0, y: 0, width: 1, height: 18), screens: screens, clientWindow: window))
    #expect(!PersonalOpening.isUsableAnchor(CGRect(x: 320, y: 180, width: 1, height: 0), screens: screens, clientWindow: window))
    #expect(!PersonalOpening.isUsableAnchor(CGRect(x: CGFloat.nan, y: 180, width: 1, height: 18), screens: screens, clientWindow: window))
    #expect(!PersonalOpening.isUsableAnchor(CGRect(x: 1e9, y: 1e9, width: 1, height: 18), screens: screens, clientWindow: window))
    // 画面の外・入力先のアプリのウィンドウの外・ウィンドウが見つからない
    #expect(!PersonalOpening.isUsableAnchor(CGRect(x: 3000, y: 180, width: 1, height: 18), screens: screens, clientWindow: window))
    #expect(!PersonalOpening.isUsableAnchor(CGRect(x: 1300, y: 900, width: 1, height: 18), screens: screens, clientWindow: window))
    #expect(!PersonalOpening.isUsableAnchor(caret, screens: screens, clientWindow: nil))
}

@Test func openingStaysTheFirstSentenceAndNeverGrowsIntoTheWholeMessage() {
    // 1 回の確定に複数の文: 最初の文だけ
    var step = PersonalOpening.append("", "お疲れさまです。経費の件ですが、確認をお願いします。")
    #expect(step.capture == nil)
    #expect(step.opening == "お疲れさまです。")
    // 句ごとに確定: 文末まで集めて止める
    step = PersonalOpening.append("", "お疲れ")
    #expect(step.capture == "お疲れ" && step.opening == nil)
    step = PersonalOpening.append(step.capture!, "さまです。来週の")
    #expect(step.capture == nil && step.opening == "お疲れさまです。")
    // 文末のない長い文（集め終わりの合図がない）: 40 字を超えたら集めるのをやめ、記録もしない
    var capture: String? = ""
    var opening: String?
    var commits = 0
    while let current = capture, commits < 100 {
        (capture, opening) = PersonalOpening.append(current, "ここは句読点のない長い文章で")
        commits += 1
        #expect((capture?.count ?? 0) <= PersonalOpening.maximumLength)
    }
    #expect(capture == nil)
    #expect(opening == nil)
    #expect(commits <= 4)
}

// MARK: - 場面の場所（アクセシビリティ、任意。フェーズ 4）

@Test func placeHostIsNormalizedAndOnlyHttp() {
    #expect(PersonalPlace.host(of: URL(string: "https://www.GitHub.com/org/repo?x=1#y")!) == "github.com")
    #expect(PersonalPlace.host(of: URL(string: "http://mail.google.com/mail/u/0/")!) == "mail.google.com")
    #expect(PersonalPlace.host(of: URL(string: "https://example.com./a")!) == "example.com")
    for url in ["file:///Users/a/b.txt", "about:blank", "chrome://settings", "data:text/plain,abc", "blob:https://x.com/123",
                "chrome-extension://abcdef/popup.html", "safari-web-extension://x/y", "https:///nohost"] {
        #expect(URL(string: url).flatMap(PersonalPlace.host(of:)) == nil)
    }
}

@Test func placeholderLabelSkipsEmptyAndGenericAndIsAShortCode() {
    #expect(PersonalPlace.placeholderLabel("") == nil)
    #expect(PersonalPlace.placeholderLabel("  ") == nil)
    #expect(PersonalPlace.placeholderLabel("検索") == nil)
    #expect(PersonalPlace.placeholderLabel("Message") == nil)
    let label = PersonalPlace.placeholderLabel("#general へメッセージ")!
    #expect(label.hasPrefix("ph:") && label.count == 9)
    #expect(!label.contains("general"))
    #expect(PersonalPlace.placeholderLabel("#general へメッセージ ") == label)
    #expect(PersonalPlace.placeholderLabel("#random へメッセージ") != label)
}

@Test func sceneKeysAreUnchangedWithoutAPlaceAndRoundTripWithOne() {
    // 場所がなければ、場所を入れる前と同じキー・段
    #expect(chatLine.key == "com.example.chat|line|new|-")
    #expect(chatLine.baseKey == chatLine.key)
    #expect(PersonalTuner.levelKeys(for: chatLine) == [chatLine.key, "app:com.example.chat", "global"])
    #expect(PersonalScene(key: chatLine.key) == chatLine)
    var github = chatLine
    github.place = "github.com"
    #expect(github.key == "com.example.chat|line|new|-|github.com")
    #expect(PersonalScene(key: github.key) == github)
    #expect(PersonalScene.baseKey(of: github.key) == chatLine.key)
    #expect(github.base == chatLine)
    #expect(PersonalTuner.levelKeys(for: github) == [github.key, chatLine.key, "app:com.example.chat", "global"])
    // アプリごとに消す段の判定は場所つきでも同じ
    #expect(PersonalLearner.level(github.key, belongsTo: "com.example.chat"))
}

@Test func placesDoNotSlowLearningAtTheSceneLevel() {
    func at(_ place: String?) -> PersonalScene {
        var scene = chatLine
        scene.place = place
        return scene
    }
    let learner = PersonalLearner(storeURL: nil)
    // 自動辞書: 別々の場所で 2 回選んでも、場所を除いた場面では 2 回（今までと同じ）で先頭に置く
    commit(learner, at("a.example"), reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1000)
    commit(learner, at("b.example"), reading: "シズク", surface: "雫", defaultSurface: "しずく", at: 1001)
    #expect(learner.preferredEntry(forReading: "シズク", scene: at(nil))?.surface == "雫")
    #expect(learner.preferredEntry(forReading: "シズク", scene: at("c.example"))?.surface == "雫")
    // 場所つきの段だけで決まれば、その場所ではそれを使う
    commit(learner, at("c.example"), reading: "シズク", surface: "滴", defaultSurface: "しずく", at: 1002)
    commit(learner, at("c.example"), reading: "シズク", surface: "滴", defaultSurface: "しずく", at: 1003)
    #expect(learner.preferredEntry(forReading: "シズク", scene: at("c.example"))?.surface == "滴")

    // 言い直し: 場所をまたいで 3 回なら、場所を除いた場面で出す
    for place in ["a.example", "b.example", "a.example"] {
        learner.recordRewrite(scene: at(place), deleted: "了解しました", written: "承知しました", writtenReading: "ショウチシマシタ")
    }
    #expect(learner.rewriteSuggestion(scene: at("d.example"), firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == "承知しました")
    #expect(learner.rewriteSuggestion(scene: at(nil), firstCandidate: "了解しました", reading: "りょうかいしました", repeats: 3) == "承知しました")

    // 書き出し: 場所をまたいで 5 回なら、場所を除いた場面で出す
    for place in ["a.example", "b.example", "c.example", "a.example", "b.example"] {
        learner.recordOpening(scene: at(place), text: "お疲れさまです。")
    }
    #expect(learner.openingSuggestion(scene: at("e.example")) == "お疲れさまです。")
    #expect(learner.openingSuggestion(scene: at(nil)) == "お疲れさまです。")

    // 手本の文: 場所つきで書いた文も、場所を除いた場面で選ぶ
    learner.recordCommit(.init(scene: at("a.example"), kind: "enter", reading: nil, surface: "議事録を共有します。", defaultSurface: nil))
    learner.recordCommit(.init(scene: at("b.example"), kind: "enter", reading: nil, surface: "議事録を確認しました。", defaultSurface: nil))
    #expect(learner.corpus.retrieve(query: "議事録", scene: at(nil), excluding: "").count >= 2)
}

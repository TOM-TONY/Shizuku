import Foundation
import Testing
@testable import Core

// llm-ime: 退けた提案の記憶・AI への指示の場面・直前の文の清書

@Test func dismissedOfferMemorySuppressesTheSameAndNearOffersOnlyInTheSameScene() {
    var memory = DismissedOfferMemory()
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(memory.remember("明日の会議は10時からでお願いします。", scene: "a|line|new|0", app: "a", now: now) != nil)
    #expect(memory.suppresses("明日の会議は10時からでお願いします。", scene: "a|line|new|0", now: now))
    // 句読点・空白・かなの違いは同じとみなす
    #expect(memory.suppresses("明日の会議は 10時からでお願いします", scene: "a|line|new|0", now: now))
    // 言い回しが少し違うだけの案も出さない
    #expect(memory.suppresses("明日の会議は10時からでお願いいたします。", scene: "a|line|new|0", now: now))
    // 違う内容・違う場面は出してよい
    #expect(!memory.suppresses("資料は金曜までに送ります。", scene: "a|line|new|0", now: now))
    #expect(!memory.suppresses("明日の会議は10時からでお願いします。", scene: "b|line|new|0", now: now))
    // 7 日たったら忘れる
    #expect(!memory.suppresses("明日の会議は10時からでお願いします。", scene: "a|line|new|0", now: now.addingTimeInterval(8 * 86400)))
}

@Test func dismissedOfferMemoryUsesVectorsOnlyWhenBothSidesHaveThem() {
    var memory = DismissedOfferMemory()
    guard let id = memory.remember("よろしくお願いします", scene: "s", app: "a") else { Issue.record("not remembered"); return }
    #expect(!memory.suppresses("今後ともご指導のほど", scene: "s", vector: [1, 0]))
    memory.attach(vector: [1, 0], to: id)
    #expect(memory.suppresses("今後ともご指導のほど", scene: "s", vector: [0.9, 0.1]))
    #expect(!memory.suppresses("今後ともご指導のほど", scene: "s", vector: [0, 1]))
    #expect(!memory.suppresses("今後ともご指導のほど", scene: "s"))
}

@Test func dismissedOfferMemoryHasBoundsAndForgets() {
    var memory = DismissedOfferMemory()
    for i in 0..<(DismissedOfferMemory.perSceneLimit + 5) { memory.remember("案その\(i)番の文です", scene: "s", app: "a") }
    #expect(memory.entries.count == DismissedOfferMemory.perSceneLimit)
    #expect(memory.remember("あ", scene: "s", app: "a") == nil)
    memory.remember("別アプリで退けた文", scene: "t", app: "b")
    memory.forget(app: "a")
    #expect(memory.entries.map(\.app) == ["b"])
    memory.removeAll()
    #expect(memory.entries.isEmpty)
}

@Test func aiDirectedScenesDoNotChangeStoredKeys() {
    let terminal = PersonalScene(app: "com.apple.Terminal", shape: .code, mode: .append, reply: false)
    let claude = PersonalScene(app: "com.anthropic.claudefordesktop", shape: .short, mode: .new, reply: false)
    let browser = PersonalScene(app: "com.google.Chrome", shape: .short, mode: .new, reply: false, place: "claude.ai")
    let mail = PersonalScene(app: "com.apple.mail", shape: .doc, mode: .new, reply: true)
    #expect(terminal.aiDirected && claude.aiDirected && browser.aiDirected)
    #expect(!mail.aiDirected)
    #expect(!PersonalScene(app: "com.google.Chrome", shape: .short, mode: .new, reply: false, place: "example.com").aiDirected)
    #expect(browser.key.split(separator: "|").count == 5 && browser.key.hasSuffix("|claude.ai"))
    #expect(PersonalScene(key: claude.key) == claude)
}

@Test func cleanUpTargetsTheSentenceBeforeTheCaret() {
    #expect(CleanUp.lastSentence("昨日はありがとう。今日のけんだけどあしたにしたい。")?.sentence == "今日のけんだけどあしたにしたい。")
    #expect(CleanUp.lastSentence("昨日はありがとう。今日のけんだけどあしたにしたい。")?.before == "昨日はありがとう。")
    #expect(CleanUp.lastSentence("「了解です。」と言った。\n")?.sentence == "「了解です。」と言った。")
    #expect(CleanUp.lastSentence("1行目\nこれをなおして")?.sentence == "これをなおして")
    #expect(CleanUp.lastSentence("。") == nil)
    #expect(CleanUp.lastSentence("") == nil)
    #expect(CleanUp.lastSentence(String(repeating: "あ", count: 201)) == nil)
}

@Test func cleanUpRejectsAddedFactsLargeRewritesAndNoChanges() {
    let original = "明日の10時のかいぎ、資料はおくれそうです"
    #expect(CleanUp.accept(original: original, result: "明日の10時の会議、資料は遅れそうです。") == "明日の10時の会議、資料は遅れそうです。")
    #expect(CleanUp.accept(original: original, result: "文章: 明日の10時の会議、資料は遅れそうです。") == "明日の10時の会議、資料は遅れそうです。")
    // 元にない数字を足した
    #expect(CleanUp.accept(original: original, result: "明日の10時の会議、資料は15時に遅れそうです。") == nil)
    // 全角の数字は同じ数字とみなす
    #expect(CleanUp.accept(original: original, result: "明日の１０時の会議、資料は遅れそうです。") != nil)
    // 長さが大きく変わった（説明を返した・切れた）
    #expect(CleanUp.accept(original: original, result: "会議") == nil)
    #expect(CleanUp.accept(original: original, result: original + "なお、詳しい理由については追ってご連絡いたしますので、少々お待ちください。") == nil)
    // 差がない・空白だけの差
    #expect(CleanUp.accept(original: original, result: original) == nil)
    #expect(CleanUp.accept(original: "了解です", result: "了解 です") == nil)
}

@Test func cleanUpInstructionChangesOnlyForAIDirectedScenes() {
    let ai = LocalLLMPrompts.cleanUpInstruction(aiDirected: true)
    let human = LocalLLMPrompts.cleanUpInstruction(aiDirected: false)
    #expect(ai.contains("読み手は AI") && !human.contains("読み手は AI"))
    #expect(ai.contains("事実") && human.contains("事実"))
}

@Test func cleanUpOfferSitsWithTheFixesAndNeedsPatternsContent() {
    #expect(OfferKind.cleanup.tier == OfferKind.typo.tier)
    #expect(AssistanceSettings.permits(.cleanup, timing: .stopped, content: .patterns))
    #expect(AssistanceSettings.permits(.cleanup, timing: .typing, content: .patterns))
    #expect(!AssistanceSettings.permits(.cleanup, timing: .called, content: .patterns))
    #expect(AssistanceSettings.permits(.cleanup, timing: .called, content: .patterns, automatic: false))
    #expect(!AssistanceSettings.permits(.cleanup, timing: .typing, content: .past, automatic: false))
}

@Test func stylePlanCanKeepHonorificsWhileNormalizingOrthography() {
    let plan = PersonalStylePlan(preferences: [0: 0])
    #expect(plan.apply("了解", honorifics: false) == "了解。")
    #expect(PersonalGeneratedText.apply("了解", route: .transform, enabled: true, plan: plan, honorifics: false) == "了解。")
    #expect(PersonalGeneratedText.apply("了解", route: .proofread, enabled: true, plan: plan, honorifics: false) == "了解")
}

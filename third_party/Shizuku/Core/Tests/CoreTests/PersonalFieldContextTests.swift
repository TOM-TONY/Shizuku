import Foundation
import Testing
@testable import Core

@Test func fieldContextRequiresTheWholeKnownTruncatedSuffix() {
    var field = PersonalFieldContext()
    let text = String(repeating: "あ", count: 150) + String(repeating: "い", count: 100)
    field.append(text, authored: true)
    #expect(field.restoredLeft(String(repeating: "い", count: 100)) == text)
    #expect(field.restoredLeft(String(repeating: "い", count: 99)) == String(repeating: "い", count: 99))
    #expect(field.restoredLeft("不一致") == "不一致")
    #expect(field.buffer.isEmpty)
    field.append(text, authored: true)
    #expect(field.restoredLeft(nil) == nil && field.buffer.isEmpty)
}
@Test func fieldContextIsBoundedAuthoredOnlyAndClearedOnFieldReset() {
    var field = PersonalFieldContext()
    field.append(String(repeating: "あ", count: 2100), authored: true)
    #expect(field.buffer.count == 2000)
    field.append("提案", authored: false)
    #expect(field.buffer.isEmpty)
    field.append("本人。", authored: true)
    field.finish(now: 10, sent: true)
    #expect(field.completionLeft("続き", now: 130) == "本人。\n続き")
    #expect(field.completionLeft("続き", now: 130.01) == "続き")
    #expect(field.completionLeft("続き", now: 9) == "続き")
    field.reset()
    #expect(field.completionLeft("続き", now: 20) == "続き" && field.buffer.isEmpty)
}
@Test func fieldContextLastSentenceAndCarryAreNotTheWholeField() {
    #expect(PersonalFieldContext.lastSentence("一文目。最後です。\n") == "最後です。")
    #expect(PersonalFieldContext.lastSentence("一文目。文末なし") == "文末なし")
    var field = PersonalFieldContext()
    field.append("前。最後。", authored: true)
    field.finish(now: 0, sent: true)
    #expect(field.completionLeft("", now: 1) == "最後。\n")
    field.append("新しい欄。", authored: true)
    field.finish(now: 1, sent: false)
    #expect(field.completionLeft("", now: 2).isEmpty)
}
@Test func appCarryHasAnExactTimeWindowAndExcludedAppsCannotBeEitherEnd() {
    var memory = PersonalAppCarry()
    memory.observe(app: "a", allowed: true, now: 0)
    memory.append(String(repeating: "あ", count: 250), app: "a", authored: true)
    memory.append("モデル", app: "a", authored: false)
    memory.observe(app: "b", allowed: true, now: 10)
    #expect(memory.prefix(now: 130) == String(repeating: "あ", count: 200) + "\n")
    #expect(memory.prefix(now: 130.1).isEmpty)
    #expect(memory.prefix(now: 20, app: "a").isEmpty)
    memory.observe(app: "excluded", allowed: false, now: 11)
    #expect(memory.prefix(now: 12).isEmpty)
    memory.append("秘密", app: "excluded", authored: true)
    memory.observe(app: "c", allowed: true, now: 12)
    #expect(memory.prefix(now: 13).isEmpty)
    memory.append("本人。", app: "c", authored: true)
    memory.observe(app: "d", allowed: true, now: 14, previousApp: "unobserved")
    #expect(memory.prefix(now: 14).isEmpty)
    memory.append("消した文。", app: "d", authored: true)
    memory.discardOwn(app: "d")
    memory.observe(app: "e", allowed: true, now: 15)
    #expect(memory.prefix(now: 15).isEmpty)
}
@Test func markupThreeHundredAuthoredExamples() {
    var correct = 0
    let normal = ["今日は晴れです。", "3 - 2 を計算", "記号#を含む文", "a > b の比較", "普通のメールです。", "費用は * 概算です", "On Monday", "引用ではない文章", "codeという単語", "-1度です"]
    let md = ["# 見出し", "## 小見出し", "- 箇条書き", "* 箇条書き", "> 引用\n- 語句", "本文の`語句`です", "### 見出し", "#### 見出し", "##### 見出し", "###### 見出し"]
    let code = ["    実行する", "\t実行する", "let value = 1", "var value = 2", "func work() {", "def work():", "class Work:", "import Foundation", "const value = 1", "```swift\n本文\n```"]
    for i in 0..<10 {
        for text in normal { if PersonalMarkup.shape(left: text + String(i), right: "", monospaced: i % 2 == 0) == nil { correct += 1 } }
        for text in md { if PersonalMarkup.shape(left: text + String(i), right: "", monospaced: false) == .md { correct += 1 } }
        for text in code { if PersonalMarkup.shape(left: text + String(i), right: "", monospaced: true) == .code { correct += 1 } }
    }
    #expect(correct == 300)
    #expect(PersonalMarkup.shape(left: "> メールの引用", right: "", monospaced: false) == nil)
    #expect(PersonalMarkup.shape(left: "> 引用", right: "", monospaced: true) == .md)
    #expect(PersonalMarkup.shape(left: "普通の文章", right: "", monospaced: true) == nil)
    #expect(PersonalMarkup.body("# 見出し\n> `本文`\n- 語句\n```swift\n    実行\n```") == "見出し\n本文\n語句\n実行")
}
@Test func markupOldSceneKeysAndDefaultClassifierRemainUnchanged() {
    for key in ["app|line|new|-", "app|short|append|reply|host", "app|doc|edit|-||r2"] {
        #expect(PersonalScene(key: key)?.key == key)
    }
    for shape in [PersonalScene.Shape.code, .md] {
        let scene = PersonalScene(app: "app", shape: shape, mode: .new, reply: false)
        #expect(PersonalScene(key: scene.key) == scene)
    }
    let obs = ConverterSceneObservation(bundleID: "app", monospaced: true)
    #expect(PersonalScene.classify(observation: obs, leftContext: "> 引用", rightContext: "")?.shape == .line)
    #expect(PersonalScene.classify(observation: obs, leftContext: "> 引用", rightContext: "")?.reply == true)
}

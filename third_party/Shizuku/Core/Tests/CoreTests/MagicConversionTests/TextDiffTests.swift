@testable import Core
import Testing

@Test func textDiffFindsEachCorrectionAsHunk() {
    let original = "来週の会義で説明したいと思いますので、お時間を頂けますでしょか。"
    let revised = "来週の会議で説明したいと思いますので、お時間を頂けますでしょうか。"
    let hunks = TextDiff.hunks(from: original, to: revised)
    #expect(hunks.map(\.originalText) == ["義", ""])
    #expect(hunks.map(\.replacement) == ["議", "う"])
    #expect(TextDiff.apply(hunks, to: original) == revised)
}

@Test func textDiffAppliesOnlyAcceptedHunks() {
    let original = "会義でしょか"
    let hunks = TextDiff.hunks(from: original, to: "会議でしょうか")
    #expect(hunks.count == 2)
    #expect(TextDiff.apply([hunks[0]], to: original) == "会議でしょか")
    #expect(TextDiff.apply([hunks[1]], to: original) == "会義でしょうか")
    #expect(TextDiff.apply([], to: original) == original)
}

@Test func textDiffHandlesDeletionAndIdenticalText() {
    #expect(TextDiff.hunks(from: "同じ文です。", to: "同じ文です。").isEmpty)
    let hunks = TextDiff.hunks(from: "資料をを送ります", to: "資料を送ります")
    #expect(hunks.count == 1)
    #expect(hunks[0].replacement.isEmpty)
    #expect(TextDiff.apply(hunks, to: "資料をを送ります") == "資料を送ります")
}

@Test func localLLMPromptsParseSuggestions() {
    #expect(LocalLLMPrompts.parseSuggestions("[\"少し遅れます。\", \"少々遅れます。\"]") == ["少し遅れます。", "少々遅れます。"])
    #expect(LocalLLMPrompts.parseSuggestions("1. 候補A\n2. 候補B\n- 候補A") == ["候補A", "候補B"])
    #expect(LocalLLMPrompts.cleanProofreadOutput("文章: 「直した文」") == "直した文")
}

@Test func textDiffDetectsWhitespaceOnlyHunks() {
    let hunks = TextDiff.hunks(from: "Gemma 4 を使う", to: "Gemma4を使う。")
    #expect(hunks.contains { TextDiff.isWhitespaceOnly($0) })
    #expect(hunks.contains { !TextDiff.isWhitespaceOnly($0) })
}

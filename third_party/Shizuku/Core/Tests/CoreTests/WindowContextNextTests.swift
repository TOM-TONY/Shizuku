@testable import Core
import Foundation
import KanaKanjiConverterModule
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// llm-ime: ウィンドウ文脈の返信先・ターミナル・欄の全文・固有名詞・意味の検索・短い返答の案内・効果の記録

private func glossaryCandidate(_ text: String) -> Candidate {
    Candidate(text: text, value: -20, composingCount: .inputCount(4), lastMid: MIDData.一般.mid,
              data: [DicdataElement(word: text, ruby: "コウセイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -20)])
}

private struct FixedEmbedder: WindowTextEmbedder {
    let table: [String: [Float]]
    func embed(_ text: String, asQuery: Bool) -> [Float]? {
        table.first { text.contains($0.key) }?.value ?? [0, 0, 1]
    }
}

@Test func replyTargetIsTheNearestTextAboveTheField() {
    let editing = CGRect(x: 100, y: 500, width: 400, height: 40)
    let reference = WindowReference(identity: "chat", capturedAt: 0, blocks: [
        .init(text: "昨日の資料ありがとうございました。", rect: CGRect(x: 100, y: 200, width: 400, height: 20), role: "AXStaticText"),
        .init(text: "明日の会議は10時からで大丈夫ですか？", rect: CGRect(x: 100, y: 440, width: 400, height: 20), role: "AXStaticText"),
        .init(text: "送信", rect: CGRect(x: 520, y: 500, width: 40, height: 20), role: "AXStaticText"),
        .init(text: "ヘルプを見る", rect: CGRect(x: 100, y: 470, width: 200, height: 20), role: "AXLink"),
        .init(text: "下に表示される注意書きです", rect: CGRect(x: 100, y: 600, width: 400, height: 20), role: "AXStaticText"),
    ], editing: editing)
    #expect(reference.replyTarget?.text == "明日の会議は10時からで大丈夫ですか？")
    #expect(WindowReference(identity: "x", capturedAt: 0, blocks: reference.blocks).replyTarget == nil)
}

@Test func terminalBlocksKeepOnlyLinesBeforeThePromptAndDropSecrets() {
    let screen = "$ claude\n案を3つ出しました。\n1. キャッシュを足す\n2. 索引を作り直す\n\nexport TOKEN=sk-dummy-test-key-not-a-real-secret-0000\n> 2で"
    let blocks = WindowReference.terminalBlocks(fieldBefore: screen)
    let joined = blocks.map(\.text).joined(separator: "\n")
    #expect(joined.contains("2. 索引を作り直す"))
    #expect(!joined.contains("sk-dummy") && !joined.contains("TOKEN="))
    #expect(!joined.contains("> 2で"))
    #expect(blocks.allSatisfy { $0.role == "AXTerminal" })
}

@Test func extendedContextUsesTheFieldOnlyWhenTheClientContextMatches() {
    let field = String(repeating: "前の段落の文章。", count: 50) + "今の文の途中"
    let reference = WindowReference(identity: "f", capturedAt: 0, blocks: [], fieldBefore: field)
    let extended = reference.extendedContext("今の文の途中")
    #expect(extended == field)
    #expect(WindowReference(identity: "g", capturedAt: 0, blocks: [], fieldBefore: String(repeating: "あ", count: 3000) + "今の文の途中").extendedContext("今の文の途中").count == 1000)
    #expect(reference.extendedContext("別の文") == "別の文")
    #expect(reference.extendedContext("") == "")
    #expect(WindowReference(identity: "f", capturedAt: 0, blocks: []).extendedContext("今の文の途中") == "今の文の途中")
}

@Test func glossaryPromotesOneOnScreenSurfaceFromBelowTheTopFive() {
    let reference = WindowReference(identity: "doc", capturedAt: 0, blocks: [.init(text: "株式会社コウセイ工房との打ち合わせ")])
    var list = ["構成", "校正", "公正", "更生", "厚生", "後世", "恒星", "コウセイ工房"].map(glossaryCandidate)
    let promoted = reference.promoteGlossary(list, whole: { _ in true })
    #expect(promoted.map(\.text) == ["構成", "コウセイ工房", "校正", "公正", "更生", "厚生", "後世", "恒星"])
    // 上位 5 にすでに画面の表記があれば動かさない
    list = ["構成", "コウセイ工房", "公正", "更生", "厚生", "後世"].map(glossaryCandidate)
    #expect(reference.promoteGlossary(list, whole: { _ in true }).map(\.text) == list.map(\.text))
    // 読み全体の候補でなければ動かさない
    let others = ["構成", "校正", "公正", "更生", "厚生", "後世", "コウセイ工房"].map(glossaryCandidate)
    #expect(reference.promoteGlossary(others, whole: { _ in false }).map(\.text) == others.map(\.text))
}

@Test func retrievalPutsTheReplyTargetFirstAndFusesSemanticRanks() {
    let editing = CGRect(x: 0, y: 500, width: 400, height: 40)
    let reference = WindowReference(identity: "chat", capturedAt: 0, blocks: [
        .init(text: "請求書の締め切りは月末です", rect: CGRect(x: 0, y: 100, width: 400, height: 20)),
        .init(text: "週末は雨の予報でした", rect: CGRect(x: 0, y: 200, width: 400, height: 20)),
        .init(text: "経費の精算は来週までにお願いします", rect: CGRect(x: 0, y: 460, width: 400, height: 20)),
    ], editing: editing)
    let retrieval = WindowReferenceRetrieval()
    let lexical = retrieval.select(reference: reference, query: "請求書", limit: 1)
    #expect(lexical == "経費の精算は来週までにお願いします\n請求書の締め切りは月末です")
    // 字面が違っても、埋め込みが近ければ拾う
    retrieval.setEmbedder(FixedEmbedder(table: ["天気": [1, 0, 0], "雨": [1, 0, 0]]), identity: "fixed")
    let semantic = retrieval.select(reference: reference, query: "天気", limit: 1)
    #expect(semantic == "経費の精算は来週までにお願いします\n週末は雨の予報でした")
    let fused = WindowReferenceRetrieval.fuse(
        [.init(text: "a"), .init(text: "b")], [.init(text: "b"), .init(text: "c")])
    #expect(fused.map(\.text) == ["b", "a", "c"])
}

@Test func shortRepliesPointToOneOptionOnScreen() {
    let reference = WindowReference(identity: "ai", capturedAt: 0, blocks: [
        .init(text: "次のどれにしますか？\n1. キャッシュを足す\n2. 索引を作り直す\n3. 何もしない"),
        .init(text: "案A: 小さく直す\n案B: 全体を作り直す"),
    ])
    #expect(ShortReplyHint.resolve("2で", reference: reference) == "2. 索引を作り直す")
    #expect(ShortReplyHint.resolve("②", reference: reference) == "2. 索引を作り直す")
    #expect(ShortReplyHint.resolve("案B", reference: reference) == "案B: 全体を作り直す")
    #expect(ShortReplyHint.resolve("Go", reference: reference) == nil)
    #expect(ShortReplyHint.resolve("5で", reference: reference) == nil)
    #expect(ShortReplyHint.resolve("それでお願いします、2番目の案で", reference: reference) == nil)
    let ambiguous = WindowReference(identity: "ai", capturedAt: 0, blocks: [.init(text: "1. 前の案\n1. 別の一覧")])
    #expect(ShortReplyHint.resolve("1", reference: ambiguous) == nil)
}

@Test func windowEffectCountsShownAndAcceptedByReferenceUse() {
    var effect = WindowReferenceEffect()
    let now = 1_000_000.0
    for kind in [("completion", true, false), ("completion", true, true), ("completion", false, false), ("cleanup", true, false)] {
        effect.observe(reaction: WindowReferenceEffect.reaction(kind: kind.0, used: kind.1, accepted: kind.2), ts: now)
    }
    effect.observe(reaction: "completion_shown", ts: now)
    effect.observe(reaction: "wref_x_completion_shown", ts: now)
    effect.observe(reaction: WindowReferenceEffect.reaction(kind: "idle", used: true, accepted: false), ts: now - 61 * 86400)
    let counts = effect.counts(now: now)
    #expect(counts[.init(kind: "completion", used: true)]?.shown == 1)
    #expect(counts[.init(kind: "completion", used: true)]?.accepted == 1)
    #expect(counts[.init(kind: "completion", used: false)]?.shown == 1)
    #expect(counts[.init(kind: "idle", used: true)]?.shown == 0)
    #expect(effect.summary(now: now).contains("completion 参考あり: 採用1/表示1"))
    #expect(WindowReferenceEffect().summary(now: now).contains("まだ記録がありません"))
}

@Test func referenceSectionKeepsPromptsByteIdenticalWithoutReference() {
    let plain = LocalLLMPrompts.transformUserPrompt(text: "文", instruction: "整える", before: "前", after: "")
    #expect(LocalLLMPrompts.transformUserPrompt(text: "文", instruction: "整える", before: "前", after: "", reference: "") == plain)
    #expect(LocalLLMPrompts.transformUserPrompt(text: "文", instruction: "整える", before: "前", after: "", reference: "相手の発言").hasPrefix("画面に表示されている参考資料"))
    let proof = LocalLLMPrompts.proofreadUserPrompt(text: "文", before: "", after: "")
    #expect(LocalLLMPrompts.proofreadUserPrompt(text: "文", before: "", after: "", reference: "  ") == proof)
    let magic = LocalLLMPrompts.suggestionUserPrompt(leftContext: "", target: "りょうかい", style: "")
    #expect(LocalLLMPrompts.suggestionUserPrompt(leftContext: "", target: "りょうかい", style: "", reference: "") == magic)
    #expect(LocalLLMPrompts.suggestionUserPrompt(leftContext: "", target: "りょうかい", style: "", reference: "明日来られますか").contains("明日来られますか"))
}

// llm-ime: 次の依頼の予想（返信先から、本人が次に AI へ送りそうな 1 文）

@Test func nextPromptSourceTakesTheReplyAndTheConversationAboveIt() {
    let editing = CGRect(x: 100, y: 800, width: 400, height: 40)
    let reference = WindowReference(identity: "codex", capturedAt: 0, blocks: [
        .init(text: "モデル3のトークンページを開いて", rect: CGRect(x: 300, y: 100, width: 200, height: 20), role: "AXStaticText"),
        .init(text: "トークン設定ページを開きました。本人確認画面が出ているので、パスワードを入力してください。", rect: CGRect(x: 100, y: 300, width: 400, height: 40), role: "AXStaticText"),
        .init(text: "サイドバーの項目", rect: CGRect(x: 0, y: 500, width: 50, height: 20), role: "AXStaticText"),
        .init(text: "下に表示される注意書きです", rect: CGRect(x: 100, y: 900, width: 400, height: 20), role: "AXStaticText"),
    ], editing: editing)
    let source = NextPrompt.source(reference, terminal: false)
    #expect(source?.reply == "トークン設定ページを開きました。本人確認画面が出ているので、パスワードを入力してください。")
    #expect(source?.earlier == "モデル3のトークンページを開いて")
    #expect(NextPrompt.source(WindowReference(identity: "x", capturedAt: 0, blocks: reference.blocks), terminal: false) == nil)
}

@Test func nextPromptSourceInTerminalsIsTheLastBlockBeforeThePrompt() {
    let blocks = WindowReference.terminalBlocks(fieldBefore: "$ claude\n> テストを直して\n\n直しました。全部のテストが通りました。\n> ")
    let source = NextPrompt.source(WindowReference(identity: "t", capturedAt: 0, blocks: blocks), terminal: true)
    #expect(source?.reply == "直しました。全部のテストが通りました。")
    #expect(source?.earlier.contains("テストを直して") == true)
}

@Test func nextPromptWaitsUntilTheReplyStopsChanging() {
    var stability = NextPrompt.Stability()
    let observed = [(1, 0.0), (1, 1.0), (2, 2.0), (2, 3.0), (2, 3.5)].map { stability.observe($0.0, now: $0.1) }
    // 返答が変わっている間（まだ書いている）は作らず、同じまま 1.5 秒続いたら作る
    #expect(observed == [false, false, false, false, true])
}

@Test func nextPromptOutputIsOneCleanRequest() {
    #expect(NextPrompt.clean("次の依頼：「認証したので、トークンの設定を進めてくれる？」\n説明: ...") == "認証したので、トークンの設定を進めてくれる？")
    #expect(NextPrompt.clean("\n- テストも追加して\n") == "テストも追加して")
    #expect(NextPrompt.clean("   ") == nil)
    #expect(NextPrompt.clean(String(repeating: "長", count: NextPrompt.maximumLength + 1)) == nil)
}

@Test func nextPromptRejectsInventedNumbersAndCopies() {
    let blocks: [WindowReferenceBlock] = [.init(text: "モデル3のページを開きました。パスワードを入力して確認を押してください。", role: "AXTerminal")]
    let source = NextPrompt.source(WindowReference(identity: "t", capturedAt: 0, blocks: blocks), terminal: true)!
    #expect(NextPrompt.permits("認証したので、モデル3のトークン設定を進めてくれる？", source: source))
    #expect(!NextPrompt.permits("モデル4のトークンを作って", source: source))
    #expect(!NextPrompt.permits("パスワードを入力して確認を押してください。", source: source))
    let prompt = NextPrompt.userPrompt(source, examples: ["これ進めてくれる？"])
    #expect(prompt.contains("モデル3のページを開きました"))
    #expect(prompt.contains("- これ進めてくれる？"))
}

@Test func nextPromptPrefersTheAccessibilityReplyOverOCRText() {
    let editing = CGRect(x: 100, y: 800, width: 400, height: 40)
    let reply = WindowReferenceBlock(text: "トークン設定ページを開きました。確認してください。", rect: CGRect(x: 100, y: 600, width: 400, height: 40),
                                     source: .accessibility, role: "AXStaticText")
    let label = WindowReferenceBlock(text: "作業しました", rect: CGRect(x: 100, y: 700, width: 200, height: 20), source: .ocr)
    let axOnly = WindowReference(identity: "codex", capturedAt: 0, blocks: [reply], editing: editing)
    let withOCR = WindowReference(identity: "codex", capturedAt: 0, blocks: [reply, label], editing: editing, fieldEmpty: true)
    // 文字認識を足した後も返信先が変わらない（変わると、落ち着くのを待ち続けて生成が始まらない）
    #expect(NextPrompt.source(axOnly, terminal: false)?.fingerprint == NextPrompt.source(withOCR, terminal: false)?.fingerprint)
    #expect(withOCR.replyTarget?.text == "作業しました")
    #expect(withOCR.fieldEmpty == true && axOnly.fieldEmpty == nil)
}

@Test func nextPromptSkipsShortWorkLabelsAndMatchesTheSameReplyAcrossReads() {
    let editing = CGRect(x: 100, y: 800, width: 400, height: 40)
    let reply = WindowReferenceBlock(text: "こんにちは！今日は何をしましょうか？", rect: CGRect(x: 100, y: 600, width: 400, height: 20),
                                     source: .ocr, role: nil)
    let label = WindowReferenceBlock(text: "10s間作業しました", rect: CGRect(x: 100, y: 700, width: 200, height: 20), source: .accessibility)
    let reference = WindowReference(identity: "codex", capturedAt: 0, blocks: [reply, label], editing: editing)
    // 「作業しました」などの短いラベルより、文の長さの本文を返信先にする
    #expect(NextPrompt.source(reference, terminal: false)?.reply == "こんにちは！今日は何をしましょうか？")
    // 空白の入り方が違う読み取りでも、同じ返答がまだ画面にあると分かる
    let reread = WindowReference(identity: "codex", capturedAt: 1, blocks: [
        .init(text: "こんにちは！ 今日は何をしましょうか？", rect: CGRect(x: 100, y: 600, width: 400, height: 20), source: .accessibility),
    ], editing: editing)
    #expect(NextPrompt.isShown("こんにちは！今日は何をしましょうか？", in: reread))
    #expect(!NextPrompt.isShown("別の返答です。テストを追加しました。", in: reread))
    #expect(NextPrompt.related("今日は何をしましょうか？", "こんにちは！今日は何をしましょうか？"))
}

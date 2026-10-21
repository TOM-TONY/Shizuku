import Foundation
import Testing
@testable import Core

// MARK: - 解析と学習 段階 B: 埋め込みの字句分割

/// llm-ime の build/models（ダウンロードした公式のモデル。git 管理外）。なければ確かめない
private let llmImeRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func unigramTokenizerMatchesHuggingFaceTokenizers() throws {
    let models = llmImeRoot.appendingPathComponent("build/models", isDirectory: true)
    let tokenizerURL = models.appendingPathComponent("ruri-v3-30m@24899e5de370/tokenizer.json")
    let referenceURL = models.appendingPathComponent("ruri-v3-30m-tokenizer-reference.json")
    guard FileManager.default.fileExists(atPath: tokenizerURL.path), FileManager.default.fileExists(atPath: referenceURL.path) else {
        return
    }
    struct Row: Decodable {
        var text: String
        var ids: [Int32]
    }
    let tokenizer = try UnigramTokenizer(tokenizerJSON: tokenizerURL)
    let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: referenceURL))
    for row in rows {
        #expect(tokenizer.encode(row.text) == row.ids, "\(row.text): \(tokenizer.encode(row.text)) vs \(row.ids)")
    }
    let fixed = tokenizer.encode(rows[0].text, length: 16)
    #expect(fixed.ids.count == 16 && fixed.mask.count == 16)
    #expect(fixed.ids.first == tokenizer.bosID)
    #expect(fixed.mask.reduce(0, +) == Int32(rows[0].ids.count + 2))
}

// MARK: - 解析と学習 段階 B: 手本選びに意味の近さを足す

private func unit(_ values: [Float]) -> [Float] {
    let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return values.map { $0 / norm }
}

/// PersonalCorpus の static（意味の近さの重み）を変えるテストは、同時に走らないようにここにまとめる
@Suite(.serialized) struct CorpusStaticTests {}

extension CorpusStaticTests {
/// 意味の近さ（問いのベクトル）を渡さない・重みが 0 のときは、BM25 だけのときと同じ手本を選ぶ。渡すと、文字の重なりのない
/// 意味の近い文も上に来る
@Test func semanticFusionKeepsBM25WhenOffAndAddsMeaningWhenOn() {
    let scene = PersonalScene(app: "test.app", shape: .short, mode: .append, reply: false)
    let corpus = PersonalCorpus()
    let texts = ["経費の申請をお願いします。", "経費精算の締め切りは金曜日です。", "明日の会議は十時からです。", "領収書を添付して提出してください。"]
    for (index, text) in texts.enumerated() {
        corpus.add(scene: scene, text: text, ts: Double(index))
    }
    let before = corpus.retrieve(query: "経費の", scene: scene, excluding: "")
    // 領収書の文だけが問いに近いベクトル（文字の 2-gram は重ならない）
    let vectors: [String: [Float]] = [
        texts[0]: unit([1, 0, 0.2]), texts[1]: unit([1, 0.1, 0]), texts[2]: unit([0, 1, 0]), texts[3]: unit([0, 0, 1]),
    ]
    corpus.embedMissing { vectors[$0] }
    #expect(corpus.dimension == 3)
    #expect(corpus.sentencesWithoutVectors(limit: 10).isEmpty)
    let query = unit([0, 0, 1])
    let saved = PersonalCorpus.semanticWeight
    defer {
        PersonalCorpus.semanticWeight = saved
    }
    PersonalCorpus.semanticWeight = 0
    #expect(corpus.retrieve(query: "経費の", scene: scene, excluding: "", queryVector: query) == before)
    PersonalCorpus.semanticWeight = 1
    #expect(corpus.retrieve(query: "経費の", scene: scene, excluding: "") == before)
    let fused = corpus.retrieve(query: "経費の", scene: scene, excluding: "", queryVector: query).map(\.text)
    #expect(fused.contains(texts[3]))
    #expect(!before.map(\.text).contains(texts[3]))
    #expect(fused.first == texts[3] || fused.first == before.first?.text)
}
}

/// ベクトルは文といっしょに残る（アプリごとの削除・全部の削除で消える）。入れ替わった文・次元の違うベクトルは入れない
@Test func corpusVectorsFollowSentences() {
    let a = PersonalScene(app: "a.app", shape: .short, mode: .append, reply: false)
    let b = PersonalScene(app: "b.app", shape: .short, mode: .append, reply: false)
    let corpus = PersonalCorpus()
    corpus.add(scene: a, text: "一つ目の文です。", ts: 0)
    corpus.add(scene: b, text: "二つ目の文です。", ts: 1)
    corpus.add(scene: a, text: "三つ目の文です。", ts: 2)
    let missing = corpus.sentencesWithoutVectors(limit: 10)
    #expect(missing.map(\.text) == ["三つ目の文です。", "二つ目の文です。", "一つ目の文です。"])
    corpus.setVector([1, 0], id: missing[0].id, text: "違う文。")
    #expect(corpus.dimension == 0)
    for (index, item) in missing.enumerated() {
        corpus.setVector(unit([Float(index + 1), 1]), id: item.id, text: item.text)
    }
    corpus.setVector([1, 0, 0], id: missing[0].id, text: missing[0].text)
    #expect(corpus.dimension == 2)
    #expect(corpus.semanticRanking(unit([1, 1]), depth: 10).count == 3)
    corpus.removeApp("b.app")
    #expect(corpus.sentences.map(\.text) == ["一つ目の文です。", "三つ目の文です。"])
    #expect(corpus.sentencesWithoutVectors(limit: 10).isEmpty)
    // 三つ目に [1, 1]、一つ目に [3, 1] を入れたので、[1, 1] に近い順は三つ目 → 一つ目
    #expect(corpus.semanticRanking(unit([1, 1]), depth: 10).map { corpus.sentences[$0].text } == ["三つ目の文です。", "一つ目の文です。"])
    corpus.add(scene: b, text: "四つ目の文です。", ts: 3)
    #expect(corpus.sentencesWithoutVectors(limit: 10).map(\.text) == ["四つ目の文です。"])
    corpus.removeAll()
    #expect(corpus.dimension == 0 && corpus.sentences.isEmpty)
}

/// ModelCatalog は文の埋め込みのフォルダ（embedding.json）を embedding として見つけ、足りないファイルを問題として出す。
/// 包んだモデル（build/embedding/ruri-v3-30m-coreml。git 管理外）があれば、読んで単位長のベクトルを作れる
@Test func embeddingModelInCatalog() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
    let folder = directory.appendingPathComponent("ruri-v3-30m-coreml", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let info = ModelCatalog.EmbeddingInfo(length: 64, dimension: 256, queryPrefix: "", documentPrefix: "", source: "test@0", license: "apache-2.0")
    try JSONEncoder().encode(info).write(to: folder.appendingPathComponent("embedding.json"))
    let incomplete = ModelCatalog.model(named: "ruri-v3-30m-coreml", kind: .embedding, in: directory)
    #expect(incomplete?.kind == .embedding && incomplete?.isUsable == false)
    #expect(ModelCatalog.models(kind: .completion, in: directory).isEmpty && ModelCatalog.models(kind: .chat, in: directory).isEmpty)
    #expect(ModelCatalog.embeddingInfo(at: folder) == info)

    let packaged = llmImeRoot.appendingPathComponent("build/embedding/ruri-v3-30m-coreml", isDirectory: true)
    guard FileManager.default.fileExists(atPath: packaged.appendingPathComponent("embedder.mlmodelc").path) else {
        return
    }
    let embedder = try PersonalEmbedder(directory: packaged)
    let a = try #require(embedder.embed("経費の申請をお願いします。", asQuery: false))
    let b = try #require(embedder.embed("経費精算の締め切りは金曜日です。", asQuery: false))
    let c = try #require(embedder.embed("明日は晴れるでしょう。", asQuery: false))
    #expect(a.count == 256)
    #expect(abs(PersonalEmbedder.similarity(a, a) - 1) < 0.01)
    #expect(PersonalEmbedder.similarity(a, b) > PersonalEmbedder.similarity(a, c))
}

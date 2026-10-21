import Foundation

// MARK: - 解析と学習で動かせる値（llm-ime、解析と学習 段階 A）
//
// 既定は、解析を入れる前の定数と同じ。一度も採用していない（版がない）・学習がオフなら既定のままで、挙動は今と同じ。
// 採用は ConverterServer が答え合わせの結果を確かめてから行い、版として残す（LabVersionStore）。

public struct LabParameters: Codable, Equatable, Sendable {
    /// 続き予測の手本の合計の長さ（文字）（PersonalCorpus.prefixCharacterBudget）
    public var exemplarBudget: Int
    /// 手本を選ぶ BM25 の k1・b
    public var bm25K1: Double
    public var bm25B: Double
    /// 自動辞書: 場面の段で先頭に置くまでの回数（PersonalLearner.sceneThreshold）
    public var sceneThreshold: Int
    /// 自動辞書: 最も多い票が 2 番目の何倍以上なら先頭に置くか（場面・アプリ・全体の段と、文脈の段）
    public var promotionMargin: Double
    public var contextPromotionMargin: Double
    /// 手本選びに足す意味の近さの重み（段階 B。PersonalCorpus.semanticWeight）。既定は 0（BM25 だけ）。
    /// 合成の記録での結果では変えず、本人の記録での答え合わせを通ったときだけ 0 より大きくなる
    public var semanticWeight: Double
    /// 文体・話題と LoRA の成果物の SHA-256。本文は版の成果物にだけ持つ。
    public var knowledgeID: String?
    public var adapterID: String?

    public init(
        exemplarBudget: Int = 160, bm25K1: Double = 1.2, bm25B: Double = 0.75, sceneThreshold: Int = 2,
        promotionMargin: Double = 3.0, contextPromotionMargin: Double = 2.0, semanticWeight: Double = 0,
        knowledgeID: String? = nil, adapterID: String? = nil
    ) {
        self.exemplarBudget = exemplarBudget
        self.bm25K1 = bm25K1
        self.bm25B = bm25B
        self.sceneThreshold = sceneThreshold
        self.promotionMargin = promotionMargin
        self.contextPromotionMargin = contextPromotionMargin
        self.semanticWeight = semanticWeight
        self.knowledgeID = knowledgeID
        self.adapterID = adapterID
    }

    enum CodingKeys: String, CodingKey {
        case exemplarBudget, bm25K1, bm25B, sceneThreshold, promotionMargin, contextPromotionMargin, semanticWeight, knowledgeID, adapterID
    }

    /// 段階 B より前の版（semanticWeight がない manifest）も読めるように、ない値は既定にする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LabParameters()
        self.exemplarBudget = try c.decodeIfPresent(Int.self, forKey: .exemplarBudget) ?? defaults.exemplarBudget
        self.bm25K1 = try c.decodeIfPresent(Double.self, forKey: .bm25K1) ?? defaults.bm25K1
        self.bm25B = try c.decodeIfPresent(Double.self, forKey: .bm25B) ?? defaults.bm25B
        self.sceneThreshold = try c.decodeIfPresent(Int.self, forKey: .sceneThreshold) ?? defaults.sceneThreshold
        self.promotionMargin = try c.decodeIfPresent(Double.self, forKey: .promotionMargin) ?? defaults.promotionMargin
        self.contextPromotionMargin = try c.decodeIfPresent(Double.self, forKey: .contextPromotionMargin) ?? defaults.contextPromotionMargin
        self.semanticWeight = try c.decodeIfPresent(Double.self, forKey: .semanticWeight) ?? defaults.semanticWeight
        self.knowledgeID = try c.decodeIfPresent(String.self, forKey: .knowledgeID)
        self.adapterID = try c.decodeIfPresent(String.self, forKey: .adapterID)
    }

    /// 解析を入れる前の定数
    public static let defaults = LabParameters()

    /// 動かしてよい範囲（評価で確かめた範囲。採用の前に ConverterServer が確かめる）
    public var isWithinBounds: Bool {
        (80...240).contains(self.exemplarBudget) && (0.8...2.0).contains(self.bm25K1) && (0.5...1.0).contains(self.bm25B)
            && (2...3).contains(self.sceneThreshold) && (2.0...4.0).contains(self.promotionMargin)
            && (1.5...3.0).contains(self.contextPromotionMargin) && (0.0...2.0).contains(self.semanticWeight)
            && LabArtifact.validDigest(self.knowledgeID) && LabArtifact.validDigest(self.adapterID)
    }

    /// 組ごとの選択結果を落とさずに一つの案へまとめる。
    public func merging(lexicon: Self, corpus: Self) -> Self {
        var result = self
        result.sceneThreshold = lexicon.sceneThreshold
        result.promotionMargin = lexicon.promotionMargin
        result.contextPromotionMargin = lexicon.contextPromotionMargin
        result.exemplarBudget = corpus.exemplarBudget
        result.bm25K1 = corpus.bm25K1
        result.bm25B = corpus.bm25B
        result.semanticWeight = corpus.semanticWeight
        return result
    }

    /// 比べるための決まった表し方（キーを並べた JSON）。「元に戻す」で前の版とバイト単位で同じかを確かめる
    public func canonicalJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// 今使っている値（ConverterServer が起動時・採用・元に戻すときに入れる）
    nonisolated(unsafe) public private(set) static var current = LabParameters.defaults

    /// 値を入れて、場面学習の各所に反映する（主スレッドで呼ぶ）
    public static func apply(_ parameters: LabParameters) {
        Self.current = parameters
        PersonalCorpus.prefixCharacterBudget = parameters.exemplarBudget
        PersonalCorpus.bm25K1 = parameters.bm25K1
        PersonalCorpus.bm25B = parameters.bm25B
        PersonalCorpus.semanticWeight = parameters.semanticWeight
        PersonalLearner.sceneThreshold = parameters.sceneThreshold
        PersonalLearner.promotionMargin = parameters.promotionMargin
        PersonalLearner.contextPromotionMargin = parameters.contextPromotionMargin
        PersonalLearner.shared.invalidateEntryCache()
    }
}

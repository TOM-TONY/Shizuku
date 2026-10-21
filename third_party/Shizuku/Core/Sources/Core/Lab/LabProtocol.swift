import Foundation

// MARK: - ShizukuLab と ConverterServer のやり取り（llm-ime、解析と学習 段階 A）
//
// ConverterServer が記録の写しを作り、ShizukuLab を起動する。ShizukuLab は置き場所（staging）に進み具合・結果と固定した名前の成果物を書く。
// 採否は ConverterServer が決める: 写しの ID・境目が自分の作ったものと同じか、案の値が範囲内か、案が変えた値の組（family）を自分で
// 求め、その組の決まり（LabRules）で項目ごとの差から判定を計算し直す（ShizukuLab の判定は使わない）。

public struct LabRunResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// 案があり、取り置き分で比べた
        case candidate
        /// 今の版より良い案がなかった
        case noCandidate
        /// 記録が足りない
        case insufficient
    }

    public var runID: String
    public var snapshotID: String
    public var split: Double
    public var status: Status
    public var baseline: LabParameters
    public var candidate: LabParameters?
    public var seed: UInt64
    /// 取り置き分の項目ごとの差（案 − 今の版）
    public var items: [LabGate.Item]
    /// ShizukuLab の判定（参考。ConverterServer は計算し直す）
    public var decision: LabGate.Decision?
    public var counts: [String: Int]
    /// 飛ばした段とその理由（例: 続き予測が E2B）
    public var skipped: [String]
    public var notes: [String]
    public var dataFrom: Double?
    public var dataTo: Double?
    public var elapsed: Double
    public var artifacts: [LabArtifact] = []

    public init(
        runID: String, snapshotID: String, split: Double, status: Status, baseline: LabParameters, candidate: LabParameters?, seed: UInt64,
        items: [LabGate.Item], decision: LabGate.Decision?, counts: [String: Int], skipped: [String], notes: [String],
        dataFrom: Double?, dataTo: Double?, elapsed: Double, artifacts: [LabArtifact] = []
    ) {
        self.runID = runID
        self.snapshotID = snapshotID
        self.split = split
        self.status = status
        self.baseline = baseline
        self.candidate = candidate
        self.seed = seed
        self.items = items
        self.decision = decision
        self.counts = counts
        self.skipped = skipped
        self.notes = notes
        self.dataFrom = dataFrom
        self.dataTo = dataTo
        self.elapsed = elapsed
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case runID, snapshotID, split, status, baseline, candidate, seed, items, decision, counts, skipped, notes, dataFrom, dataTo, elapsed, artifacts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(runID: try c.decode(String.self, forKey: .runID), snapshotID: try c.decode(String.self, forKey: .snapshotID),
                  split: try c.decode(Double.self, forKey: .split), status: try c.decode(Status.self, forKey: .status),
                  baseline: try c.decode(LabParameters.self, forKey: .baseline), candidate: try c.decodeIfPresent(LabParameters.self, forKey: .candidate),
                  seed: try c.decode(UInt64.self, forKey: .seed), items: try c.decode([LabGate.Item].self, forKey: .items),
                  decision: try c.decodeIfPresent(LabGate.Decision.self, forKey: .decision), counts: try c.decode([String: Int].self, forKey: .counts),
                  skipped: try c.decode([String].self, forKey: .skipped), notes: try c.decode([String].self, forKey: .notes),
                  dataFrom: try c.decodeIfPresent(Double.self, forKey: .dataFrom), dataTo: try c.decodeIfPresent(Double.self, forKey: .dataTo),
                  elapsed: try c.decode(Double.self, forKey: .elapsed), artifacts: try c.decodeIfPresent([LabArtifact].self, forKey: .artifacts) ?? [])
    }
}

/// 進み具合（progress.jsonl の 1 行）
public struct LabProgress: Codable, Equatable, Sendable {
    public var stage: String
    public var fraction: Double
    public var note: String

    public init(stage: String, fraction: Double, note: String) {
        self.stage = stage
        self.fraction = fraction
        self.note = note
    }
}

/// 採否の決まり（ConverterServer が持つ。ShizukuLab も同じものを使う）
public enum LabRules {
    /// 値の組
    public enum Family: String, Codable, Sendable, CaseIterable {
        /// 自動辞書（場面のしきい値・票の差）→ 変換 top1
        case lexicon
        /// 手本の選び方（長さ・BM25）→ 続き予測の節約文字
        case corpus
        /// 文体の説明と LoRA → いい感じ変換 F1
        case magic
    }

    /// 悪くならない幅（下限がこれより下なら捨てる）
    public static let margins: [String: Double] = ["top1": 0.002, "saved": 0.005, "notWrong": 0.005, "f1": 0.005, "magicTime": 0.15]
    public static let minimumMagicItems = 64

    /// 復元抽出の種（決まった値。同じ記録なら毎回同じ区間になり、採否が実行ごとの偶然で変わらない）
    public static let seed: UInt64 = 0x5EED_1AB0_0000_0001

    /// 案が今の版から変えた値の組
    public static func families(baseline: LabParameters, candidate: LabParameters) -> Set<Family> {
        var families: Set<Family> = []
        if baseline.sceneThreshold != candidate.sceneThreshold || baseline.promotionMargin != candidate.promotionMargin
            || baseline.contextPromotionMargin != candidate.contextPromotionMargin {
            families.insert(.lexicon)
        }
        if baseline.exemplarBudget != candidate.exemplarBudget || baseline.bm25K1 != candidate.bm25K1 || baseline.bm25B != candidate.bm25B
            || baseline.semanticWeight != candidate.semanticWeight {
            families.insert(.corpus)
        }
        if baseline.knowledgeID != candidate.knowledgeID || baseline.adapterID != candidate.adapterID { families.insert(.magic) }
        return families
    }

    /// 変えた組の主な指標は良くなること、ほかの指標は悪くならないこと
    public static func rules(for families: Set<Family>) -> [LabGate.Rule] {
        [
            LabGate.Rule(metric: "top1", primary: families.contains(.lexicon), margin: Self.margins["top1"]!),
            LabGate.Rule(metric: "saved", primary: families.contains(.corpus), margin: Self.margins["saved"]!),
            LabGate.Rule(metric: "notWrong", primary: false, margin: Self.margins["notWrong"]!),
            LabGate.Rule(metric: "f1", primary: families.contains(.magic), margin: Self.margins["f1"]!),
            LabGate.Rule(metric: "magicTime", primary: false, margin: Self.margins["magicTime"]!),
        ]
    }

    /// ConverterServer の確かめ: 写しの ID・境目・今の値が渡したものと同じ、案が範囲内、変えた組があり、計算し直した判定
    /// （種は決まった値）が採用なら、採用してよい案を返す
    public static func verify(
        _ result: LabRunResult, runID: String, snapshotID: String, split: Double, baseline: LabParameters
    ) -> (candidate: LabParameters, decision: LabGate.Decision)? {
        guard result.runID == runID, result.snapshotID == snapshotID, result.split == split, result.baseline == baseline, result.status == .candidate,
              let candidate = result.candidate, candidate.isWithinBounds else {
            return nil
        }
        let families = Self.families(baseline: result.baseline, candidate: candidate)
        guard !families.isEmpty else {
            return nil
        }
        if families.contains(.magic) {
            let magic = result.items.filter { $0.diffs["f1"] != nil }
            guard magic.count >= Self.minimumMagicItems, magic.allSatisfy({ $0.diffs["magicTime"] != nil }),
                  Set(magic.map(\.day)).count >= 7 else { return nil }
        }
        guard result.items.allSatisfy({ $0.diffs.values.allSatisfy(\.isFinite) }) else { return nil }
        let decision = LabGate.decide(items: result.items, rules: Self.rules(for: families), seed: Self.seed)
        return decision.accepted ? (candidate, decision) : nil
    }
}

/// 実行の終わり方から、採用するかを決める（ConverterServer が使う。止めた・失敗した・結果が合わないときは何も採用しない）
public enum LabOutcome: Equatable, Sendable {
    case stopped(String)
    case failed
    case insufficient(LabRunResult)
    case noCandidate(LabRunResult)
    case rejected(LabRunResult, [String])
    case adopt(LabRunResult, LabParameters, LabGate.Decision)

    public static func decide(
        exitStatus: Int32, stopReason: String?, resultData: Data?, runID: String, snapshotID: String, split: Double, baseline: LabParameters
    ) -> LabOutcome {
        if let stopReason {
            return .stopped(stopReason)
        }
        guard exitStatus == 0, let resultData, let result = try? JSONDecoder().decode(LabRunResult.self, from: resultData) else {
            return .failed
        }
        switch result.status {
        case .insufficient:
            return .insufficient(result)
        case .noCandidate:
            return .noCandidate(result)
        case .candidate:
            if let verified = LabRules.verify(result, runID: runID, snapshotID: snapshotID, split: split, baseline: baseline) {
                return .adopt(result, verified.candidate, verified.decision)
            }
            var reasons: [String] = []
            if result.runID != runID || result.snapshotID != snapshotID || result.split != split || result.baseline != baseline {
                reasons.append("結果が今回の実行のものではない")
            } else if let candidate = result.candidate {
                if !candidate.isWithinBounds {
                    reasons.append("案の値が範囲外")
                } else {
                    let families = LabRules.families(baseline: result.baseline, candidate: candidate)
                    reasons += LabGate.decide(items: result.items, rules: LabRules.rules(for: families), seed: LabRules.seed).reasons
                }
            }
            return .rejected(result, reasons)
        }
    }
}

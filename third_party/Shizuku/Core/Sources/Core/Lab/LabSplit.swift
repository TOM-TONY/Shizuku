import Foundation

// MARK: - 答え合わせ用の取り置き（llm-ime、解析と学習 段階 A）
//
// 記録を時間で分ける。直近 2 週間を答え合わせ用に取り置き、それより前を学習に使う。学習に使う側（索引・文体の説明・アダプタ・
// 手本・自動辞書を作るもの）は LabTrainView だけを通して記録を読み、答え合わせ用の文が混ざらないようにする。

public struct LabSplit: Codable, Equatable, Sendable {
    /// これより前（ts < split）が学習、以後が答え合わせ
    public var split: Double

    public init(split: Double) {
        self.split = split
    }

    public static let heldOutDays = 14.0

    /// 記録の最後の時刻から、取り置きの境目を決める
    public static func make(lastCommit: Double) -> LabSplit {
        LabSplit(split: lastCommit - Self.heldOutDays * 86400)
    }

    public func isTrain(_ ts: Double) -> Bool {
        ts < self.split
    }
}

/// 解析に使う確定 1 件（記録の写しから読む）
public struct LabCommit: Codable, Equatable, Sendable {
    public var origin: Int
    public var isMaterial: Bool { PersonalOrigin.isMaterial(origin) }
    public var ts: Double
    public var scene: String
    public var kind: String
    public var reading: String?
    public var surface: String
    public var first: String?
    public var left: String?

    public init(ts: Double, scene: String, kind: String, reading: String?, surface: String, first: String?, left: String?, origin: Int = 0) {
        self.origin = origin
        self.ts = ts
        self.scene = scene
        self.kind = kind
        self.reading = reading
        self.surface = surface
        self.first = first
        self.left = left
    }
    private enum CodingKeys: String, CodingKey { case origin, ts, scene, kind, reading, surface, first, left }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ts: try c.decode(Double.self, forKey: .ts), scene: try c.decode(String.self, forKey: .scene),
                  kind: try c.decode(String.self, forKey: .kind), reading: try c.decodeIfPresent(String.self, forKey: .reading),
                  surface: try c.decode(String.self, forKey: .surface), first: try c.decodeIfPresent(String.self, forKey: .first),
                  left: try c.decodeIfPresent(String.self, forKey: .left), origin: try c.decodeIfPresent(Int.self, forKey: .origin) ?? 0)
    }
}

/// 学習に使う側だけの記録（答え合わせ用の文は入らない）
public struct LabTrainView: Sendable {
    public let split: LabSplit
    public let commits: [LabCommit]

    public init(_ all: [LabCommit], split: LabSplit) {
        self.split = split
        self.commits = all.filter { split.isTrain($0.ts) }
    }
}

/// 答え合わせ用の記録（学習には使わない）
public struct LabHeldOut: Sendable {
    public let split: LabSplit
    public let commits: [LabCommit]

    public init(_ all: [LabCommit], split: LabSplit) {
        self.split = split
        self.commits = all.filter { !split.isTrain($0.ts) }
    }
}

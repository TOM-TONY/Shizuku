import Foundation

/// 本人が退けた提案の記憶（llm-ime）。同じ場面では、退けたものと意味の近い提案も出さない。
/// 記憶の中だけに持ち、ファイルには書かない。照合は文字 2-gram の Jaccard と、あれば埋め込みのコサイン。
public struct DismissedOfferMemory: Sendable {
    public static let jaccardThreshold = 0.6
    public static let cosineThreshold: Float = 0.85
    public static let perSceneLimit = 50
    public static let totalLimit = 500
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public struct Entry: Sendable {
        public var id: Int
        public var scene: String
        public var app: String
        public var normalized: String
        public var grams: Set<String>
        public var vector: [Float]?
        public var ts: Double
    }

    public private(set) var entries: [Entry] = []
    private var nextID = 0
    public init() {}

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.toKatakana()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// 退けた提案を覚える。返す id はあとからベクトルを付けるときに使う（覚えなかったら nil）
    @discardableResult
    public mutating func remember(_ text: String, scene: String, app: String, now: Date = Date()) -> Int? {
        let normalized = Self.normalize(text)
        guard normalized.count >= 2 else { return nil }
        let ts = now.timeIntervalSince1970
        self.expire(now: now)
        if let index = entries.firstIndex(where: { $0.scene == scene && $0.normalized == normalized }) {
            entries[index].ts = ts
            return entries[index].id
        }
        nextID += 1
        entries.append(.init(id: nextID, scene: scene, app: app, normalized: normalized,
                             grams: PersonalOrigin.grams(normalized), vector: nil, ts: ts))
        let inScene = entries.indices.filter { entries[$0].scene == scene }
        if inScene.count > Self.perSceneLimit { entries.remove(at: inScene[0]) }
        if entries.count > Self.totalLimit { entries.removeFirst(entries.count - Self.totalLimit) }
        return nextID
    }

    public mutating func attach(vector: [Float], to id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].vector = vector
    }

    /// 同じ場面で退けたものと同じ・近い提案か。vector は提案のベクトル（なければ 2-gram だけで見る）
    public func suppresses(_ text: String, scene: String, vector: [Float]? = nil, now: Date = Date()) -> Bool {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return false }
        let since = now.timeIntervalSince1970 - Self.retention
        let grams = PersonalOrigin.grams(normalized)
        for entry in entries where entry.scene == scene && entry.ts >= since {
            if entry.normalized == normalized { return true }
            if Self.jaccard(entry.grams, grams) >= Self.jaccardThreshold { return true }
            if let vector, let other = entry.vector, vector.count == other.count,
               zip(vector, other).reduce(0, { $0 + $1.0 * $1.1 }) >= Self.cosineThreshold { return true }
        }
        return false
    }

    public mutating func expire(now: Date = Date()) {
        let since = now.timeIntervalSince1970 - Self.retention
        entries.removeAll { $0.ts < since }
    }

    public mutating func forget(app: String) { entries.removeAll { $0.app == app } }
    public mutating func removeAll() { entries.removeAll() }
}

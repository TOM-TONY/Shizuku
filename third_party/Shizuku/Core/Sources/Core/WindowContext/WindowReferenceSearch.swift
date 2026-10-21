import Foundation

/// Embedders are interchangeable, but each index belongs to exactly one model and dimension.
public protocol WindowTextEmbedder: Sendable {
    func embed(_ text: String, asQuery: Bool) -> [Float]?
}
#if os(macOS)
extension PersonalEmbedder: WindowTextEmbedder {}
#endif

public struct WindowReferenceIndex: Sendable {
    public let modelIdentity: String
    private let reference: WindowReference
    private let vectors: [[Float]?]
    private let dimension: Int
    public init(reference: WindowReference, modelIdentity: String, embedder: any WindowTextEmbedder) {
        self.reference = reference; self.modelIdentity = modelIdentity
        vectors = reference.blocks.map { embedder.embed($0.text, asQuery: false) }
        dimension = vectors.compactMap { $0 }.first?.count ?? 0
    }
    public func retrieve(query: String, modelIdentity: String, embedder: any WindowTextEmbedder, limit: Int = 3) -> [WindowReferenceBlock] {
        guard self.modelIdentity == modelIdentity, let queryVector = embedder.embed(query, asQuery: true),
              queryVector.count == dimension, dimension > 0, queryVector.allSatisfy(\.isFinite) else {
            return reference.retrieve(query: query, limit: limit)
        }
        let ranked = vectors.indices.compactMap { index -> (Int, Float)? in
            guard let vector = vectors[index], vector.count == dimension, vector.allSatisfy(\.isFinite) else { return nil }
            let dot = zip(vector, queryVector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            let a = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 }), b = sqrt(queryVector.reduce(Float(0)) { $0 + $1 * $1 })
            guard a > 0, b > 0 else { return nil }
            return (index, dot / (a * b))
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return ranked.prefix(limit).map { reference.blocks[$0.0] }
    }
}

/// Retrieval can scan a window, so it must never run inside synchronous key work.
/// llm-ime: 返信先を先頭に置き、残りは BM25 と、文の埋め込みが使えればその順位を RRF で合わせて選ぶ。
public final class WindowReferenceRetrieval: @unchecked Sendable {
    public static let shared = WindowReferenceRetrieval()
    public static let fusionK = 60.0
    private let queue = DispatchQueue(label: "Shizuku.window-context.search", qos: .utility)
    private let lock = NSLock()
    private var serial: UInt64 = 0
    private var embedder: (any WindowTextEmbedder)?
    private var embedderIdentity: String?
    private var cachedIndex: (key: String, index: WindowReferenceIndex)?
    public init() {}
    public func cancel() { lock.withLock { serial &+= 1 } }

    /// 文の埋め込みを使えるようにする（nil で BM25 だけに戻す）。索引はモデルごと
    public func setEmbedder(_ embedder: (any WindowTextEmbedder)?, identity: String?) {
        lock.withLock {
            if embedderIdentity != identity { cachedIndex = nil }
            self.embedder = embedder; self.embedderIdentity = identity
        }
    }

    /// 続き予測用。新しい問いが来たら古い問いの結果は捨てる
    public func text(reference: WindowReference?, query: String) async -> String {
        guard let reference else { return "" }
        let request = lock.withLock { serial &+= 1; return serial }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard self.lock.withLock({ self.serial == request }) else { continuation.resume(returning: ""); return }
                let text = self.select(reference: reference, query: query)
                continuation.resume(returning: self.lock.withLock { self.serial == request } ? text : "")
            }
        }
    }

    /// 清書・いい感じ変換・添削用。続き予測の問いとは打ち消し合わない
    public func referenceText(reference: WindowReference?, query: String) async -> String {
        guard let reference else { return "" }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.select(reference: reference, query: query)) }
        }
    }

    /// 返信先（あれば）と、関連する部分を最大 limit 件。queue の上で呼ぶ
    func select(reference: WindowReference, query: String, limit: Int = 3) -> String {
        let query = String(query.suffix(400))
        var chosen: [WindowReferenceBlock] = []
        if let reply = reference.replyTarget { chosen.append(reply) }
        let lexical = reference.retrieve(query: query, limit: 8)
        var ranked = lexical
        let (embedder, identity, cached) = lock.withLock { (self.embedder, self.embedderIdentity, self.cachedIndex) }
        if let embedder, let identity, !query.isEmpty {
            let key = reference.identity + "\u{1F}\(reference.capturedAt)"
            let index = cached?.key == key ? cached!.index : WindowReferenceIndex(reference: reference, modelIdentity: identity, embedder: embedder)
            if cached?.key != key { lock.withLock { self.cachedIndex = (key, index) } }
            let semantic = index.retrieve(query: query, modelIdentity: identity, embedder: embedder, limit: 8)
            ranked = Self.fuse(lexical, semantic)
        }
        for block in ranked where chosen.count < limit + (reference.replyTarget == nil ? 0 : 1) {
            if !chosen.contains(where: { $0.text == block.text }) { chosen.append(block) }
        }
        return chosen.map(\.text).joined(separator: "\n")
    }

    /// 2 つの順位を RRF（k=60）で合わせる。同点は字面の順位を優先
    static func fuse(_ lexical: [WindowReferenceBlock], _ semantic: [WindowReferenceBlock]) -> [WindowReferenceBlock] {
        var scores: [String: (score: Double, first: Int, block: WindowReferenceBlock)] = [:]
        for (list, offset) in [(lexical, 0), (semantic, 1000)] {
            for (rank, block) in list.enumerated() {
                let previous = scores[block.text]
                scores[block.text] = ((previous?.score ?? 0) + 1 / (fusionK + Double(rank + 1)),
                                      min(previous?.first ?? Int.max, offset + rank), block)
            }
        }
        return scores.values.sorted { $0.score == $1.score ? $0.first < $1.first : $0.score > $1.score }.map(\.block)
    }
}

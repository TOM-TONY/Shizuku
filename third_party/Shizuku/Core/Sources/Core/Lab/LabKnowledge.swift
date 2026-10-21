import Foundation

/// 解析で得た本人の書き方。文章由来なので、版の成果物として保存し、記録の削除時に消す。
public struct LabKnowledge: Codable, Equatable, Sendable {
    public struct Card: Codable, Equatable, Sendable {
        public var scope: String
        public var style: String
        public var phrases: [String]
        public init(scope: String, style: String, phrases: [String] = []) {
            self.scope = scope; self.style = style; self.phrases = phrases
        }
    }
    public struct Topic: Codable, Equatable, Sendable {
        public var center: [Float]
        public var count: Int
        public init(center: [Float], count: Int) { self.center = center; self.count = count }
    }
    public var model: LabModelStamp
    public var embeddingSource: String?
    public var cards: [Card]
    public var topics: [Topic]

    public init(model: LabModelStamp, embeddingSource: String? = nil, cards: [Card] = [], topics: [Topic] = []) {
        self.model = model; self.embeddingSource = embeddingSource; self.cards = cards; self.topics = topics
    }
    public var isValid: Bool {
        self.cards.count <= 128 && Set(self.cards.map(\.scope)).count == self.cards.count && self.cards.allSatisfy(Self.validCard)
            && self.topics.count <= 16 && self.topics.allSatisfy {
                (1...1024).contains($0.center.count) && $0.center.allSatisfy(\.isFinite) && $0.count > 0
                    && abs($0.center.reduce(0.0) { $0 + Double($1) * Double($1) } - 1) < 0.02
            } && Set(self.topics.map { $0.center.count }).count <= 1
    }
    public static func validCard(_ card: Card) -> Bool {
        !card.scope.isEmpty && card.scope.count <= 400 && !card.style.isEmpty && card.style.count <= 320
            && !card.style.contains("<|") && !PersonalPrivacy.looksSecret(card.style)
            && card.phrases.count <= 8 && card.phrases.allSatisfy {
                (2...24).contains($0.count) && !$0.contains("<|") && !PersonalPrivacy.looksSecret($0)
            }
    }
    public static func topicIndex(vector: [Float], topics: [Topic]) -> Int? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        var best: (Int, Float)?
        for (i, topic) in topics.enumerated() where topic.center.count == vector.count {
            let dot = zip(topic.center, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            if best == nil || dot > best!.1 { best = (i, dot) }
        }
        return best.flatMap { $0.1 >= 0.4 ? $0.0 : nil }
    }
    /// 場面 → 話題 → アプリ → 全体。明示された本人のスタイル指示は呼び出し側で優先する。
    public func card(scene: PersonalScene, vector: [Float]? = nil) -> Card? {
        var keys = [scene.key, scene.baseKey]
        if let vector, let topic = Self.topicIndex(vector: vector, topics: self.topics) { keys.append("topic:\(topic)") }
        keys += ["app:\(scene.app)", "*"]
        for key in keys { if let card = self.cards.first(where: { $0.scope == key }) { return card } }
        return nil
    }
    public func instruction(scene: PersonalScene, vector: [Float]? = nil) -> String? {
        guard let card = self.card(scene: scene, vector: vector) else { return nil }
        return card.style + (card.phrases.isEmpty ? "" : "。よく使う表現の書き方だけを参考にする（内容を付け足さない）: " + card.phrases.joined(separator: "、"))
    }
    public static func read(at url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let knowledge = try? JSONDecoder().decode(Self.self, from: data), knowledge.isValid else { return nil }
        return knowledge
    }

    /// 決まった順と初期点で球面 k-means。学習側のベクトルだけを受け取り、取り置き側は渡せない。
    public static func cluster(vectors: [[Float]], maximumTopics: Int = 8) -> [Topic] {
        guard let dimension = vectors.first?.count, dimension > 0, (1...16).contains(maximumTopics) else { return [] }
        let vectors = vectors.filter { $0.count == dimension && $0.allSatisfy(\.isFinite) && $0.reduce(Float(0)) { $0 + $1 * $1 } > 0.5 }
        guard !vectors.isEmpty else { return [] }
        let k = min(maximumTopics, max(1, vectors.count / 100), vectors.count)
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        var centers = [vectors[0]]
        while centers.count < k {
            let farthest = vectors.enumerated().min { a, b in
                let x = centers.map { dot(a.element, $0) }.max() ?? 0
                let y = centers.map { dot(b.element, $0) }.max() ?? 0
                return x != y ? x < y : a.offset < b.offset
            }!.element
            if centers.contains(farthest) { break }
            centers.append(farthest)
        }
        var counts = [Int](repeating: 0, count: centers.count)
        for _ in 0..<8 {
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dimension), count: centers.count)
            counts = [Int](repeating: 0, count: centers.count)
            for vector in vectors {
                let index = centers.indices.max { a, b in
                    let x = dot(vector, centers[a]), y = dot(vector, centers[b])
                    return x != y ? x < y : a > b
                }!
                counts[index] += 1
                for j in 0..<dimension { sums[index][j] += vector[j] }
            }
            for i in centers.indices where counts[i] > 0 {
                let norm = sqrt(sums[i].reduce(Float(0)) { $0 + $1 * $1 })
                if norm > 0 { centers[i] = sums[i].map { $0 / norm } }
            }
        }
        return zip(centers, counts).filter { $0.1 > 0 }.map { Topic(center: $0.0, count: $0.1) }
    }
}

/// モデルが呼べるのはこの五つの道具だけ。SQL、ファイル名、コマンドなどの追加の引数は拒否する。
public struct LabAnalystCall: Sendable, Equatable {
    public enum Tool: String, Sendable, Codable { case inspect, examples, propose, evaluate, finish }
    public var tool: Tool
    public var scope: String?
    public var card: LabKnowledge.Card?
    public var summary: String?

    public static func parse(_ output: String, scopes: Set<String>) throws -> Self {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), let first = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: first)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.utf8.count <= 16_384, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["tool"] as? String, let tool = Tool(rawValue: name) else {
            throw LabError.invalidResult("許された道具の JSON ではない")
        }
        let allowed: Set<String>
        switch tool {
        case .inspect, .examples: allowed = ["tool", "scope"]
        case .propose: allowed = ["tool", "scope", "style", "phrases"]
        case .evaluate: allowed = ["tool"]
        case .finish: allowed = ["tool", "summary"]
        }
        guard Set(object.keys).isSubset(of: allowed) else { throw LabError.invalidResult("許されない引数がある") }
        let scope = object["scope"] as? String
        if [.examples, .propose].contains(tool) || object["scope"] != nil {
            guard let scope, scopes.contains(scope) else { throw LabError.invalidResult("未知の場面または話題") }
        }
        var card: LabKnowledge.Card?
        if tool == .propose {
            guard let scope, let style = object["style"] as? String,
                  object["phrases"] == nil || object["phrases"] is [String] else { throw LabError.invalidResult("文体の案の形式が不正") }
            card = .init(scope: scope, style: style, phrases: object["phrases"] as? [String] ?? [])
            guard LabKnowledge.validCard(card!) else { throw LabError.invalidResult("文体の案が範囲外") }
        }
        let summary = object["summary"] as? String
        if tool == .finish {
            guard let summary, !summary.isEmpty, summary.count <= 800, !PersonalPrivacy.looksSecret(summary) else {
                throw LabError.invalidResult("まとめが範囲外")
            }
        }
        return Self(tool: tool, scope: scope, card: card, summary: summary)
    }
}

public struct LabAnalysisReport: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var round: Int
        public var tool: String
        public var accepted: Bool
        public var response: String
        public var request: String
        public init(round: Int, tool: String, accepted: Bool, response: String, request: String = "") {
            self.round = round; self.tool = tool; self.accepted = accepted; self.response = response
            self.request = request
        }
    }
    public var summary: String
    public var calls: [Entry]
    public var modelName: String
    public var trainingCount: Int
    public var topicCount: Int
    public var selectedF1: Double?
    public var baselineF1: Double?
    public var loraNote: String
    public init(modelName: String, trainingCount: Int, topicCount: Int) {
        self.modelName = modelName; self.trainingCount = trainingCount; self.topicCount = topicCount
        self.summary = ""; self.calls = []; self.selectedF1 = nil; self.loraNote = "まだ学習していません"
    }
}

/// 固定した集計と手本の問い合わせ。本人の文章は LabTrainView の側だけから得る。
public struct LabAnalystData: Sendable {
    public let train: LabTrainView
    public let topics: [LabKnowledge.Topic]
    public let vectors: [String: [Float]]
    public var scopes: Set<String> {
        Set(["*"] + self.train.commits.map(\.scene) + self.train.commits.compactMap {
            PersonalScene(key: $0.scene).map { "app:" + $0.app }
        } + self.topics.indices.map { "topic:\($0)" })
    }
    public init(train: LabTrainView, topics: [LabKnowledge.Topic], vectors: [String: [Float]]) {
        self.train = train; self.topics = topics; self.vectors = vectors
    }
    public func rows(scope: String) -> [LabCommit] {
        self.train.commits.filter { row in
            guard row.isMaterial else { return false }
            if scope == "*" { return true }
            if scope.hasPrefix("app:") { return PersonalScene(key: row.scene)?.app == String(scope.dropFirst(4)) }
            if scope.hasPrefix("topic:"), let index = Int(scope.dropFirst(6)), let vector = self.vectors[row.surface] {
                return LabKnowledge.topicIndex(vector: vector, topics: self.topics) == index
            }
            return row.scene == scope
        }
    }
    public func supports(_ card: LabKnowledge.Card) -> Bool {
        guard self.scopes.contains(card.scope) else { return false }
        let rows = self.rows(scope: card.scope)
        return !rows.isEmpty && card.phrases.allSatisfy { phrase in rows.contains { $0.surface.contains(phrase) } }
    }
    public func inspect(scope: String? = nil) -> String {
        let scopes = scope.map { [$0] } ?? self.scopes.sorted().prefix(32).map { $0 }
        let stats = scopes.map { key -> [String: Any] in
            let rows = self.rows(scope: key)
            let n = max(1, rows.count)
            let polite = rows.filter { ["です。", "ます。", "でした。", "ました。"].contains(where: $0.surface.hasSuffix) }.count
            return ["scope": key, "count": rows.count, "meanLength": Double(rows.reduce(0) { $0 + $1.surface.count }) / Double(n),
                    "politeRate": Double(polite) / Double(n), "conversionChanges": rows.filter { $0.first != nil && $0.first != $0.surface }.count]
        }
        let data = (try? JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    public func examples(scope: String) -> String {
        let scoped = self.rows(scope: scope)
        let changed = scoped.filter { $0.first != nil && $0.first != $0.surface }.suffix(3)
        let normal = scoped.filter { $0.first == nil || $0.first == $0.surface }.suffix(6 - changed.count)
        let rows = (Array(changed) + Array(normal)).map { row in
            ["reading": row.reading ?? "", "chosen": String(row.surface.prefix(100)), "discarded": String((row.first ?? "").prefix(100))]
        }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}

import Accelerate
import Foundation

/// llm-ime: 本人がこれまでに書いた文（確定の記録をつないだもの）。続き予測の文脈の前に置く「本人の手本」を選ぶ。
///
/// 続けて確定した句（間が 60 秒未満、同じ場面）をつなぎ、文末（。！？）か改行で 1 文にする。
/// 手本は、今の文脈（左文脈の末尾）と文字の 2-gram が似た文を BM25 で選ぶ（場面 → アプリ → 全体の順に探す）。
/// 続き予測では手本を文脈の前に固定で置き、同じ手本の間は計算を使い回す（Gemma4Completer の prefix）
public final class PersonalCorpus: @unchecked Sendable {
    public struct Sentence: Sendable, Equatable {
        public var scene: String
        public var app: String
        public var ts: Double
        public var text: String
        /// 場所を除いた場面のキー（場所つきの場面の文も、場面の段で使う）
        public var baseScene = ""
        /// 明示して教えた他人由来かもしれない文は3。自動の本人由来の引用からは外す。
        public var origin = 0
        public var sourceID: String?
    }

    /// 探す段: 場所つきの場面（場所があるときだけ）→ 場面（場所を除く。場所つきで書いた文も含む）→ アプリ → 全体
    static func levelFilters(_ scene: PersonalScene) -> [(Sentence) -> Bool] {
        var filters: [(Sentence) -> Bool] = []
        for key in scene.refinedKeys {
            filters.append { PersonalScene.contains($0.scene, at: key) }
        }
        let base = scene.baseKey
        let app = scene.app
        filters.append { $0.baseScene == base }
        filters.append { $0.app == app }
        filters.append { _ in true }
        return filters
    }

    /// 手本の選び方
    public enum PrefixStyle: String, Sendable {
        /// 手本なし
        case none
        /// その場面の最近の文
        case recent
        /// 今の文脈に似た文（BM25）
        case retrieve
        /// 文体の要約（敬体の割合・句読点・文の長さ）＋似た文
        case card
    }

    public static let maxSentences = 20000
    public static let maxSentenceLength = 120
    /// 手本の合計の長さ（文字）。トークンにするとおよそ 0.7〜1 倍（Gemma のトークナイザ）
    nonisolated(unsafe) public static var prefixCharacterBudget = 160
    /// 手本を選ぶ BM25 の k1・b（解析と学習で動かすことがある。既定は今までの値）
    nonisolated(unsafe) public static var bm25K1 = 1.2
    nonisolated(unsafe) public static var bm25B = 0.75
    /// 意味の近さ（文の埋め込み。解析と学習 段階 B）の順位を BM25 の順位に足す重み（逆順位の和: 1/(k+BM25 の順位) + 重み/(k+意味の順位)）。
    /// 0 なら BM25 だけ（今までと同じ）。問いのベクトルを渡したときだけ使う
    nonisolated(unsafe) public static var semanticWeight = 0.0
    static let fusionK = 60.0
    static let fusionDepth = 200

    public private(set) var sentences: [Sentence] = []
    /// 文字の 2-gram → その 2-gram を含む文の番号
    private var index: [String: [Int]] = [:]
    /// 文の長さ（文字数）と合計（BM25 で毎回数えないように。String.count は文の長さに比例して時間がかかる）
    private var lengths: [Int] = []
    private var totalLength = 0
    /// 文の埋め込み（単位長。文の順に dimension 個ずつ並べる。まだ作っていない文は 0 で hasVector が false）。最初のベクトルで次元が決まる
    private var vectors: [Float] = []
    private var hasVector: [Bool] = []
    public private(set) var dimension = 0
    private var removedCount = 0
    /// いい感じ変換だけで使う、答え合わせを通った話題の段。
    public var magicTopics: [LabKnowledge.Topic] = [] { didSet { if oldValue != self.magicTopics { self.topicCache = [:] } } }
    private var topicCache: [Int: Int] = [:]
    /// 場面ごとの、文になる前の句
    private var pending: [String: (app: String, ts: Double, text: String)] = [:]

    public init() {}

    /// すべて消す
    public func removeAll() {
        self.sentences = []
        self.index = [:]
        self.lengths = []
        self.totalLength = 0
        self.pending = [:]
        self.removedCount = 0
        self.vectors = []
        self.hasVector = []
        self.dimension = 0
        self.magicTopics = []
        self.topicCache = [:]
    }

    /// そのアプリの文をすべて消す（索引も作り直す）
    public func removeApp(_ app: String) {
        let keep = self.sentences.indices.filter { self.sentences[$0].app != app }.map { (self.sentences[$0], self.vector(at: $0)) }
        self.pending = self.pending.filter { $0.value.app != app }
        self.rebuild(keep)
    }

    public func remove(before cutoff: Double) {
        let keep = self.sentences.indices.filter { self.sentences[$0].ts >= cutoff }.map { (self.sentences[$0], self.vector(at: $0)) }
        self.pending = self.pending.filter { $0.value.ts >= cutoff }
        if keep.count != self.sentences.count { self.rebuild(keep) }
    }

    /// 文（とベクトル）を入れ直して索引を作り直す
    private func rebuild(_ keep: [(Sentence, [Float]?)]) {
        self.topicCache = [:]
        self.removedCount = 0
        self.sentences = []
        self.index = [:]
        self.lengths = []
        self.totalLength = 0
        self.vectors = []
        self.hasVector = []
        for (sentence, vector) in keep {
            self.append(sentence, vector: vector)
        }
    }

    // MARK: 追加

    /// 確定した文字列を足す（場面ごとにつないで、文末で 1 文にする）
    public func add(scene: PersonalScene, text: String, ts: Double) {
        let key = scene.key
        if let parent = scene.continuationParentKey, let unfinished = self.pending[parent], !unfinished.text.isEmpty,
           ts >= unfinished.ts, ts - unfinished.ts <= 60 {
            self.flush(key)
            self.pending[key] = self.pending.removeValue(forKey: parent)
        }
        if let last = self.pending[key], ts - last.ts > 60 {
            self.flush(key)
        }
        var buffer = (self.pending[key]?.text ?? "") + text
        while let end = buffer.firstIndex(where: { "。！？!?\n".contains($0) }) {
            self.append(Sentence(scene: key, app: scene.app, ts: ts, text: String(buffer[...end])))
            buffer = String(buffer[buffer.index(after: end)...])
        }
        self.pending[key] = (scene.app, ts, buffer)
    }

    public func addTaught(scene: PersonalScene, text: String, ts: Double, id: String) {
        self.append(Sentence(scene: scene.key, app: scene.app, ts: ts, text: text, origin: 3, sourceID: id))
    }

    public func removeTaught(ids: Set<String>) {
        rebuild(sentences.indices.filter { !ids.contains(sentences[$0].sourceID ?? "") }.map { (sentences[$0], vector(at: $0)) })
    }

    private func flush(_ key: String) {
        if let entry = self.pending[key], !entry.text.isEmpty {
            self.append(Sentence(scene: key, app: entry.app, ts: entry.ts, text: entry.text))
        }
        self.pending[key] = nil
    }

    private func append(_ sentence: Sentence, vector: [Float]? = nil) {
        var sentence = sentence
        sentence.text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sentence.baseScene = PersonalScene.baseKey(of: sentence.scene)
        guard sentence.text.count >= 2, sentence.text.count <= Self.maxSentenceLength else {
            return
        }
        let id = self.removedCount + self.sentences.count
        self.sentences.append(sentence)
        let length = sentence.text.count
        self.lengths.append(length)
        self.totalLength += length
        for bigram in Set(Self.bigrams(sentence.text)) {
            self.index[bigram, default: []].append(id)
        }
        if self.dimension > 0 {
            self.vectors.append(contentsOf: [Float](repeating: 0, count: self.dimension))
            self.hasVector.append(false)
            if let vector, vector.count == self.dimension {
                self.store(vector, at: self.sentences.count - 1)
            }
        }
        if self.sentences.count > Self.maxSentences {
            self.compact()
        }
    }

    /// 古い文を半分捨てて索引を作り直す
    private func compact() {
        let start = self.sentences.count - Self.maxSentences / 2
        self.rebuild((start..<self.sentences.count).map { (self.sentences[$0], self.vector(at: $0)) })
    }

    // MARK: 文の埋め込み

    private func vector(at position: Int) -> [Float]? {
        guard self.dimension > 0, self.hasVector[position] else {
            return nil
        }
        return Array(self.vectors[(position * self.dimension)..<((position + 1) * self.dimension)])
    }

    private func store(_ vector: [Float], at position: Int) {
        self.vectors.replaceSubrange((position * self.dimension)..<((position + 1) * self.dimension), with: vector)
        self.hasVector[position] = true
    }

    /// ベクトルのある文の数（確かめ用）
    public var vectorCount: Int {
        self.hasVector.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    /// まだベクトルのない文（新しい順に limit 個まで）。id は setVector に渡す
    public func sentencesWithoutVectors(limit: Int) -> [(id: Int, text: String)] {
        var found: [(id: Int, text: String)] = []
        for position in self.sentences.indices.reversed() where found.count < limit {
            if self.dimension == 0 || !self.hasVector[position] {
                found.append((self.removedCount + position, self.sentences[position].text))
            }
        }
        return found
    }

    /// 文のベクトル（単位長）を入れる。その間に文が消えた・入れ替わったとき（text が違う）、次元が合わないときは何もしない
    public func setVector(_ vector: [Float], id: Int, text: String) {
        self.topicCache[id] = nil
        let position = id - self.removedCount
        guard !vector.isEmpty, self.sentences.indices.contains(position), self.sentences[position].text == text else {
            return
        }
        if self.dimension == 0 {
            self.dimension = vector.count
            self.vectors = [Float](repeating: 0, count: self.sentences.count * vector.count)
            self.hasVector = [Bool](repeating: false, count: self.sentences.count)
        }
        guard vector.count == self.dimension else {
            return
        }
        self.store(vector, at: position)
    }

    /// まだベクトルのない文に、まとめてベクトルを作る（評価・解析用。IME ではキーの処理の外で少しずつ作る）
    public func embedMissing(_ embed: (String) -> [Float]?) {
        for (id, text) in self.sentencesWithoutVectors(limit: Int.max) {
            if let vector = embed(text) {
                self.setVector(vector, id: id, text: text)
            }
        }
    }

    /// 問いのベクトルとの内積（コサイン類似度）の高い順に、ベクトルのある文の位置を depth 個まで
    public func semanticRanking(_ query: [Float], depth: Int) -> [Int] {
        guard self.dimension > 0, query.count == self.dimension, !self.sentences.isEmpty else {
            return []
        }
        var similarities = [Float](repeating: 0, count: self.sentences.count)
        self.vectors.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { vector in
                similarities.withUnsafeMutableBufferPointer { output in
                    cblas_sgemv(
                        CblasRowMajor, CblasNoTrans, Int32(self.sentences.count), Int32(self.dimension), 1, matrix.baseAddress, Int32(self.dimension),
                        vector.baseAddress, 1, 0, output.baseAddress, 1
                    )
                }
            }
        }
        let candidates = self.sentences.indices.filter { self.hasVector[$0] }
        return Array(candidates.sorted { similarities[$0] != similarities[$1] ? similarities[$0] > similarities[$1] : $0 > $1 }.prefix(depth))
    }

    static func bigrams(_ text: String) -> [String] {
        let characters = Array(text.filter { !$0.isWhitespace })
        guard characters.count >= 2 else {
            return characters.map(String.init)
        }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    // MARK: 手本

    /// 似た文を探す（場面 → アプリ → 全体）。文脈にすでにある文は除く
    /// before を渡すと、その時刻より前の文だけから探す（自己調整で記録を再生するとき、先の文を手本にしないように）
    /// queryVector（問いの埋め込み）を渡し、semanticWeight が 0 より大きいときは、意味の近さの順位も足して並べる
    public func retrieve(
        query: String, scene: PersonalScene, excluding context: String, limit: Int = 6, before: Double? = nil, queryVector: [Float]? = nil,
        useTopics: Bool = false, quoteOnly: Bool = false
    ) -> [Sentence] {
        let queryBigrams = Set(Self.bigrams(query))
        guard !queryBigrams.isEmpty, !self.sentences.isEmpty else {
            return []
        }
        let total = Double(self.sentences.count)
        let averageLength = Double(self.totalLength) / total
        var scores: [Int: Double] = [:]
        // 2-gram の順・同じ点の文の順を決めておく（Set・Dictionary の順はプロセスごとに変わる。手本と答え合わせを毎回同じにするため。
        // 同じ点なら新しい文を先に）
        for bigram in queryBigrams.sorted() {
            guard let postings = self.index[bigram], !postings.isEmpty else {
                continue
            }
            let idf = log(1 + (total - Double(postings.count) + 0.5) / (Double(postings.count) + 0.5))
            for id in postings {
                let length = Double(self.lengths[id - self.removedCount])
                // 文の中の回数は 1 とみなす（短い文の集まりなので）。既定は k1 = 1.2, b = 0.75
                // （既定の値では、今までの式と同じ数になるように k1 + 1 を 2.2 と書く）
                let k1 = Self.bm25K1, b = Self.bm25B
                let numerator = k1 == 1.2 ? 2.2 : k1 + 1
                scores[id, default: 0] += idf * numerator / (1 + k1 * ((1 - b) + b * length / averageLength))
            }
        }
        let tail = String(context.suffix(400))
        let bm25 = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }.map { $0.key - self.removedCount }
        let order: [Int]
        if let queryVector, Self.semanticWeight > 0, self.dimension > 0 {
            order = self.fused(bm25: bm25, query: queryVector)
        } else {
            order = bm25
        }
        // 段ごとに、上から順に段の条件 → 時刻 → 文脈にすでにあるか の順に見て、要る数が集まったらやめる
        // （文脈にあるかの確かめは文字列の検索で重いので、要る文だけ・1 回だけ行う。選ぶ文は全部を絞ってから選ぶのと同じ）
        var eligible = [UInt8](repeating: 0, count: self.sentences.count)
        func isEligible(_ position: Int) -> Bool {
            if eligible[position] == 0 {
                let sentence = self.sentences[position]
                let quoteAllowed = !quoteOnly || (sentence.origin != 3 && sentence.app == scene.app
                    && !context.contains(String(sentence.text.prefix(50))) && !PersonalPrivacy.looksSecret(sentence.text))
                eligible[position] = quoteAllowed && (before.map { sentence.ts < $0 } ?? true) && !tail.contains(sentence.text) ? 1 : 2
            }
            return eligible[position] == 1
        }
        var found: [Sentence] = []
        var filters: [(Int) -> Bool] = Self.levelFilters(scene).map { filter in { filter(self.sentences[$0]) } }
        if quoteOnly { filters.removeLast() } // 引用は場面→アプリまで。別アプリの全体へは下げない。
        if useTopics, let queryVector, let topic = LabKnowledge.topicIndex(vector: queryVector, topics: self.magicTopics) {
            filters.insert({ position in
                let id = self.removedCount + position
                if let cached = self.topicCache[id] { return cached == topic }
                guard let vector = self.vector(at: position) else { return false }
                let assigned = LabKnowledge.topicIndex(vector: vector, topics: self.magicTopics) ?? -1
                self.topicCache[id] = assigned
                return assigned == topic
            }, at: max(0, filters.count - 2))
        }
        for filter in filters {
            found = []
            var quoteTexts = Set<String>()
            for position in order where filter(position) && isEligible(position) {
                if quoteOnly, !quoteTexts.insert(String(self.sentences[position].text.prefix(50))).inserted { continue }
                found.append(self.sentences[position])
                if found.count >= max(limit, 2) {
                    break
                }
            }
            if found.count >= 2 {
                return Array(found.prefix(limit))
            }
        }
        // 最後の段（全体）でも 2 つに満たない: 全体の段で見つかったもの
        return Array(found.prefix(limit))
    }

    /// BM25 の順位と意味の近さの順位を、逆順位の和で 1 つに並べる（どちらも上位 fusionDepth 個まで。同じ点なら BM25 の順）
    func fused(bm25: [Int], query: [Float]) -> [Int] {
        var scores: [Int: Double] = [:]
        var bm25Rank: [Int: Int] = [:]
        for (rank, position) in bm25.prefix(Self.fusionDepth).enumerated() {
            scores[position, default: 0] += 1 / (Self.fusionK + Double(rank + 1))
            bm25Rank[position] = rank
        }
        for (rank, position) in self.semanticRanking(query, depth: Self.fusionDepth).enumerated() {
            scores[position, default: 0] += Self.semanticWeight / (Self.fusionK + Double(rank + 1))
        }
        let fused = scores.keys.sorted { a, b in
            scores[a]! != scores[b]! ? scores[a]! > scores[b]! : (bm25Rank[a] ?? Int.max, a) < (bm25Rank[b] ?? Int.max, b)
        }
        // 両方の上位に入らなかった BM25 の文は後ろにそのまま並べる（段ごとの絞り込みで足りなくならないように）
        return fused + bm25.dropFirst(Self.fusionDepth)
    }

    /// いい感じ変換に渡す書き方の手本: 似た文のうち短いもの（長い文は語句や内容を写されやすい）を 3 つまで
    public func styleExamples(query: String, scene: PersonalScene, excluding context: String, queryVector: [Float]? = nil) -> [String] {
        self.retrieve(query: query, scene: scene, excluding: context, limit: 10, queryVector: queryVector, useTopics: true)
            .map(\.text)
            .filter { $0.count <= 50 }
            .prefix(3)
            .map { $0 }
    }

    /// その場面の最近の文（なければアプリ、全体）
    public func recent(scene: PersonalScene, excluding context: String, limit: Int = 6) -> [Sentence] {
        let tail = String(context.suffix(400))
        for filter in Self.levelFilters(scene) {
            let found = self.sentences.reversed().filter { filter($0) && !tail.contains($0.text) }.prefix(limit)
            if found.count >= 2 {
                return Array(found.reversed())
            }
        }
        return []
    }

    /// 文体の要約（その場面の最近 200 文から）。データが少なければ nil
    public func styleCard(scene: PersonalScene) -> String? {
        let base = scene.baseKey
        var pool = self.sentences.reversed().filter { $0.baseScene == base }.prefix(200)
        if pool.count < 10 {
            pool = self.sentences.reversed().filter { $0.app == scene.app }.prefix(200)
        }
        guard pool.count >= 10 else {
            return nil
        }
        let politeEndings = ["です。", "ます。", "ました。", "でした。", "ません。", "ください。", "ます！", "です！"]
        let polite = pool.filter { s in politeEndings.contains { s.text.hasSuffix($0) } }.count
        let plainEnd = pool.filter { $0.text.hasSuffix("。") }.count
        let averageLength = pool.reduce(0) { $0 + $1.text.count } / pool.count
        let emoji = pool.filter { $0.text.unicodeScalars.contains { $0.properties.isEmojiPresentation } }.count
        var parts: [String] = []
        parts.append(polite * 2 >= plainEnd ? "です・ます調" : "だ・である調")
        parts.append("1 文 約 \(averageLength) 字")
        if emoji * 5 >= pool.count {
            parts.append("絵文字あり")
        }
        return "（" + parts.joined(separator: "、") + "）"
    }

    /// 続き予測の文脈の前に置く文章。手本の文を改行でつなぎ、最後に空行を置く。手本がなければ空
    public func completionPrefix(
        style: PrefixStyle, scene: PersonalScene, query: String, context: String, before: Double? = nil, queryVector: [Float]? = nil
    ) -> String {
        let examples: [Sentence]
        switch style {
        case .none:
            return ""
        case .recent:
            examples = self.recent(scene: scene, excluding: context)
        case .retrieve, .card:
            examples = self.retrieve(query: query, scene: scene, excluding: context, before: before, queryVector: queryVector)
        }
        var lines: [String] = []
        var length = 0
        for example in examples {
            guard length + example.text.count <= Self.prefixCharacterBudget else {
                continue
            }
            lines.append(example.text)
            length += example.text.count
        }
        guard !lines.isEmpty else {
            return ""
        }
        if style == .card, let card = self.styleCard(scene: scene) {
            lines.insert(card, at: 0)
        }
        return lines.joined(separator: "\n") + "\n\n"
    }
}

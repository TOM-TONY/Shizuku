import Core
import Foundation

// MARK: - 手本選びの意味の近さ（llm-ime、解析と学習 段階 B）
//
// 解析で意味の近さの重み（LabParameters.semanticWeight）を採用していて、文の埋め込みのモデル（ModelCatalog の embedding）があり、
// 場面学習がオンのときだけ動く（既定の重みは 0 なので、採用するまでは何もしない・モデルも読まない）。
// - 本人の文のベクトル: 操作がない間に裏で少しずつ作る（キーが来たら次のまとまりから待つ）。記憶の中だけに持ち、ファイルには書かない
//   （アプリごとの削除・全部の削除で文といっしょに消える）
// - 問いのベクトル: 確定の後に、その後ろの左文脈の末尾から裏で作っておく。入力を始めたときの左文脈と同じなら手本選びに使い、
//   違えば BM25 だけで選ぶ（キーの処理の流れでは埋め込みを作らない）

@MainActor
final class PersonalEmbeddingService {
    static let shared = PersonalEmbeddingService()

    /// 問いにする左文脈の長さ（評価と同じ）
    static let queryLength = 40
    /// 操作がない時間がこれを超えたら、本人の文のベクトルを作る
    static let idleSeconds: TimeInterval = 2
    static let batchSize = 32

    private let queue = DispatchQueue(label: "dev.tomonari.inputmethod.Shizuku.embedding", qos: .background)
    /// queue の上でだけ使う
    nonisolated(unsafe) private var embedder: PersonalEmbedder?
    private var loadedModel: URL?
    private var loading = false
    private var working = false
    private var lastKey = Date.distantPast
    private var timer: Timer?

    /// 本人の文のベクトルを作るか（重みが 0 より大きい・学習がオン）
    var corpusVectorsWanted: Bool {
        (PersonalCorpus.semanticWeight > 0 || !PersonalLearner.shared.corpus.magicTopics.isEmpty) && PersonalLearner.isEnabled
    }

    /// 使うか（本人の文のベクトルを作る、またはウィンドウ文脈がオンで画面の中を意味で探す）。使うモデルの場所
    var modelURL: URL? {
        guard self.corpusVectorsWanted || Config.WindowContextEnabled().value else {
            return nil
        }
        return Self.availableModelURL
    }

    /// 文の埋め込みのモデルがあればその場所（解析に渡す。重みに関係なく）
    static var availableModelURL: URL? {
        // 通しの確かめ（確かめ用の記録の場所を使っているときだけ）: 置き場所に入れずに、包んだモデルのフォルダを使う
        if PersonalLearner.isUsingTestStore, let path = ProcessInfo.processInfo.environment["LLM_IME_E2E_EMBEDDING_DIR"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return ModelCatalog.embeddingInfo(at: url) == nil ? nil : url
        }
        guard let model = ModelCatalog.model(named: ModelCatalog.defaultEmbeddingModel, kind: .embedding), model.isUsable else {
            return nil
        }
        return ModelCatalog.directory.appendingPathComponent(model.name, isDirectory: true)
    }

    func start() {
        self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                PersonalEmbeddingService.shared.tick()
            }
        }
    }

    func noteKey() {
        self.lastKey = Date()
    }

    /// 使わなくなったらモデルを手放す。使うなら読み、操作がない間に本人の文のベクトルを作る
    func tick() {
        guard let url = self.modelURL else {
            if self.loadedModel != nil, !self.working {
                self.loadedModel = nil
                WindowReferenceRetrieval.shared.setEmbedder(nil, identity: nil)
                self.queue.async {
                    self.embedder = nil
                }
            }
            return
        }
        guard self.ensureLoaded(url), self.corpusVectorsWanted, !self.working, Date().timeIntervalSince(self.lastKey) > Self.idleSeconds else {
            return
        }
        let corpus = PersonalLearner.shared.corpus
        let batch = corpus.sentencesWithoutVectors(limit: Self.batchSize)
        guard !batch.isEmpty else {
            return
        }
        self.working = true
        self.queue.async {
            let vectors = batch.map { self.embedder?.embed($0.text, asQuery: false) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (item, vector) in zip(batch, vectors) {
                        if let vector {
                            corpus.setVector(vector, id: item.id, text: item.text)
                        }
                    }
                    self.working = false
                    // まだ残っていれば少し置いて続ける（キーが来ていれば次の tick まで待つ）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated {
                            self.tick()
                        }
                    }
                }
            }
        }
    }

    private func ensureLoaded(_ url: URL) -> Bool {
        if self.loadedModel == url {
            return true
        }
        guard !self.loading else {
            return false
        }
        self.loading = true
        self.queue.async {
            let loaded = try? PersonalEmbedder(directory: url)
            self.embedder = loaded
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading = false
                    if loaded != nil {
                        self.loadedModel = url
                    }
                    // 画面の中を意味で探す。PersonalEmbedder は推論を 1 つずつ通すので、検索用のキューからも使える
                    WindowReferenceRetrieval.shared.setEmbedder(Config.WindowContextEnabled().value ? loaded : nil, identity: loaded == nil ? nil : url.path)
                }
            }
        }
        return false
    }

    /// モデルがすでに読まれているときだけ、文のベクトルを裏で作って主スレッドで返す（読まれていなければ何もしない）
    func embedIfLoaded(_ text: String, completion: @escaping @MainActor ([Float]) -> Void) {
        guard self.loadedModel != nil, !text.isEmpty else {
            return
        }
        let generation = PersonalLearner.shared.forgetGeneration
        self.queue.async {
            guard let vector = self.embedder?.embed(text, asQuery: false) else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard PersonalLearner.shared.forgetGeneration == generation else {
                        return
                    }
                    completion(vector)
                }
            }
        }
    }

    /// 問いのベクトルを裏で作り、できたら session に入れる（使わないとき・モデルがまだ読めていないときは何もしない）。
    /// 確定の後は、操作が止まったら新しい文のベクトルも作る
    func prepareQuery(leftContext: String, for session: ConverterSession) {
        guard self.corpusVectorsWanted, let url = self.modelURL, self.ensureLoaded(url) else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds + 0.5) {
            MainActor.assumeIsolated {
                self.tick()
            }
        }
        let text = String(leftContext.suffix(Self.queryLength))
        guard !text.isEmpty, session.personal.semanticQuery?.text != text else {
            return
        }
        let generation = PersonalLearner.shared.forgetGeneration
        // session は主スレッドでだけ触る（裏の処理では持ち運ぶだけ）
        nonisolated(unsafe) let session = session
        self.queue.async {
            guard let vector = self.embedder?.embed(text, asQuery: true) else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // その間に記録が消されていたら入れない
                    guard PersonalLearner.shared.forgetGeneration == generation else {
                        return
                    }
                    session.personal.semanticQuery = (text, vector)
                }
            }
        }
    }

    /// 入力を始めたときの左文脈に合う問いのベクトル（なければ nil。BM25 だけで選ぶ）
    func queryVector(for session: ConverterSession) -> [Float]? {
        guard self.modelURL != nil else {
            return nil
        }
        guard let left = session.personal.inputLeft, let query = session.personal.semanticQuery, query.text == left else {
            self.queryMissed += 1
            return nil
        }
        self.queryUsed += 1
        return query.vector
    }

    private var queryUsed = 0
    private var queryMissed = 0

    /// 確かめ用の表示（文章は含まない）
    var diagnostics: String {
        let corpus = PersonalLearner.shared.corpus
        let model = Self.availableModelURL == nil ? "なし" : (self.loadedModel != nil ? "読み込み済み" : "未読み込み")
        return String(
            format: "意味の近さ: 重み %.2f・モデル %@・ベクトル %d/%d 文・問いのベクトルを使った %d 回（なかった %d 回）",
            PersonalCorpus.semanticWeight, model, corpus.vectorCount, corpus.sentences.count, self.queryUsed, self.queryMissed
        )
    }
}

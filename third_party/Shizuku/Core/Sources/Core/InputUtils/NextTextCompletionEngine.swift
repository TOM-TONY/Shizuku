import Foundation
#if canImport(Gemma4ANE)
import Gemma4ANE
#endif

/// llm-ime: 文章の続き予測（Gemma 4 を Apple Neural Engine で実行）。
///
/// 推論は専用のシリアルキューで行い、キー処理（MainActor）を待たせない。新しい要求が来たら
/// 古い要求はトークン生成の合間に打ち切る。しばらく使われなければモデルを解放する。
public final class NextTextCompletionEngine: @unchecked Sendable {
    public static let shared = NextTextCompletionEngine()

    public struct Suggestion: Sendable, Equatable {
        /// 続きとして挿入する文字列
        public var text: String
        /// 候補を作るトークンの対数確率の最小値
        public var confidence: Float
        public var elapsedMilliseconds: Double
    }

    /// 自己調整の再生で、生成した 1 トークン分
    public struct Piece: Sendable, Equatable {
        public var text: String
        public var logProb: Float

        public init(text: String, logProb: Float) {
            self.text = text
            self.logProb = logProb
        }
    }

    /// 自己調整の再生の結果。打ち切られた（キー入力・時間切れ）ら、そこまでの分
    public struct ReplayResult: Sendable {
        /// 入力ごとのトークンの記録（予測できなかった入力は空）
        public var pieces: [[Piece]]
        /// キー入力（ほかの予測の要求）で打ち切られた
        public var cancelled: Bool
        /// 時間の上限で打ち切られた
        public var timedOut: Bool
        public var elapsed: TimeInterval
    }

    /// 自己調整の再生を打ち切るための番号（キー入力のたびに進める）
    private var backgroundGeneration: UInt64 = 0

    /// モデルの置き場所（ConverterServer はサンドボックス外で動くため、ホームの Application Support を読める）。
    /// 通常は E4B、省電力設定では E2B（どちらも 6bit パレット化、gemma4/convert_gemma4.py で作る）。
    /// 選んだ方が入っていなければ、入っている方を使う（配布版で一部のモデルだけ入れた場合）
    /// 設定でモデルを選んでいればそれ（使えなければ下の順）。選んでいなければ E4B、省電力なら E2B。
    /// どれもなければ、入っている続き予測のモデルの先頭
    public static func modelDirectoryURL(powerSaving: Bool) -> URL {
        let preferred = ResourceBudget.completion(powerSaving: powerSaving, selected: Config.NextTextCompletionModel().value, tier: ResourceBudget.current)
        return Self.modelDirectoryURL(powerSaving: powerSaving || preferred == "gemma4-e2b-ane", selected: Config.NextTextCompletionModel().value, in: ModelCatalog.directory)
    }

    /// 設定画面で選んだモデル（selected）が使えればそれ、なければ省電力の設定に応じて E2B・E4B の順か逆
    public static func modelDirectoryURL(powerSaving: Bool, selected: String, in directory: URL) -> URL {
        let defaults = powerSaving ? ["gemma4-e2b-ane", "gemma4-e4b-ane"] : ["gemma4-e4b-ane", "gemma4-e2b-ane"]
        return ModelCatalog.resolve(selected: selected, kind: .completion, fallbacks: defaults, in: directory)
            ?? directory.appendingPathComponent(defaults[0], isDirectory: true)
    }

    private static let idleUnloadInterval: TimeInterval = 600
    /// 評価用: 設定によらず、このモデルを使う
    nonisolated(unsafe) public static var modelDirectoryOverride: URL?
    /// 入力中の予測の自信度の下限（約 50%）。
    public static let defaultMinLogProb: Float = -0.7
    /// 何も入力していない状態（手を止めて待っている）の下限（約 30%。出る頻度を優先する）
    public static let idleMinLogProb: Float = -1.2

    private let queue = DispatchQueue(label: "dev.tomonari.llm-ime.next-text-completion", qos: .userInitiated)
    private let preemption = InferencePreemption()
    private let lock = NSLock()
    private var latestRequestID: UInt64 = 0
    /// Gemma4Completer（macOS 15 以降でのみ生成する）
    private var completer: AnyObject?
    private var loadedDirectoryURL: URL?
    private var completionRuns: UInt64 = 0
    private var lastLoadFailure: Date?
    private var unloadWorkItem: DispatchWorkItem?

    private init() {}

    private func isStale(_ id: UInt64) -> Bool {
        self.lock.withLock { self.latestRequestID != id } || self.preemption.keyPending
    }

    /// 進行中の要求を打ち切る。
    public func cancel() {
        self.lock.withLock { self.latestRequestID &+= 1 }
    }

    public func discardReferenceContext() {
        cancel()
        queue.async {
            #if canImport(Gemma4ANE)
            if #available(macOS 15.0, *) { (self.completer as? Gemma4Completer)?.discardContext() }
            #endif
        }
    }

    /// Counts only, so lifecycle checks never expose prompt or proposal text.
    public func contextCacheStatistics() async -> (modelLoaded: Bool, tokens: Int, runs: UInt64) {
        await withCheckedContinuation { continuation in
            queue.async {
                #if canImport(Gemma4ANE)
                if #available(macOS 15.0, *), let completer = self.completer as? Gemma4Completer {
                    continuation.resume(returning: (true, completer.cachedContextTokenCount, self.completionRuns)); return
                }
                #endif
                continuation.resume(returning: (false, 0, self.completionRuns))
            }
        }
    }

    public func beginKeyWork() {
        WindowReferenceRetrieval.shared.cancel()

        self.cancel()
        self.cancelBackground()
        self.preemption.beginKey()
    }
    public func endKeyWork() { self.preemption.endKey() }

    /// 裏で行っている自己調整の再生を打ち切る（キー入力のたびに呼ぶ）
    public func cancelBackground() {
        self.lock.withLock { self.backgroundGeneration &+= 1 }
    }

    /// 自己調整: 記録の各位置（文脈と手本）で、足切りなしで続きを生成してトークンごとの対数確率を集める。
    /// 予測の要求（打鍵）やキー入力が来たら、トークン生成の合間にすぐ打ち切る。budget 秒を超えたら、そこまでで返す。
    /// 予測と同じキューで動かす（同時に ANE を使わない）が、優先度は低くする
    public func replay(_ items: [(context: String, prefix: String)], budget: TimeInterval) async -> ReplayResult {
        let (requestID, generation) = self.lock.withLock { (self.latestRequestID, self.backgroundGeneration) }
        let start = Date()
        return await withCheckedContinuation { continuation in
            self.queue.async(qos: .background) {
                var result = ReplayResult(pieces: [], cancelled: false, timedOut: false, elapsed: 0)
                let interrupted: () -> Bool = {
                    self.lock.withLock { self.latestRequestID != requestID || self.backgroundGeneration != generation } || self.preemption.keyPending
                }
                #if canImport(Gemma4ANE)
                if #available(macOS 15.0, *), let completer = self.loadedCompleter() {
                    for item in items {
                        if interrupted() {
                            result.cancelled = true
                            break
                        }
                        if Date().timeIntervalSince(start) > budget {
                            result.timedOut = true
                            break
                        }
                        do {
                            guard self.preemption.enter() else { result.cancelled = true; break }
                            defer { self.preemption.leave() }
                            let pieces = try autoreleasepool(invoking: {
                                try InferenceActivity.measure(feature: "replay", device: "ANE") { try completer.completePieces(context: item.context, prefix: item.prefix, isCancelled: {
                                    interrupted() || Date().timeIntervalSince(start) > budget
                                }) }
                            })
                            result.pieces.append(pieces.map { Piece(text: $0.text, logProb: $0.logProb) })
                        } catch {
                            // 打ち切られたなら次の周で理由を判定する。それ以外の失敗は空の結果を入れて、項目と結果の並びをそろえる
                            // （呼び出し側は items と pieces を zip で対応させる）
                            if !(interrupted() || Date().timeIntervalSince(start) > budget) {
                                result.pieces.append([])
                            }
                            continue
                        }
                    }
                    self.scheduleUnload()
                }
                #endif
                result.elapsed = Date().timeIntervalSince(start)
                continuation.resume(returning: result)
            }
        }
    }

    /// トークンごとの記録から、しきい値 threshold のときに出す候補（出さなければ nil）
    public static func suggestion(from pieces: [Piece], threshold: Float) -> String? {
        #if canImport(Gemma4ANE)
        if #available(macOS 15.0, *) {
            return Gemma4Completer.suggestion(
                from: pieces.map { .init(text: $0.text, logProb: $0.logProb, isPunctuationOnly: false) }, threshold: threshold
            )
        }
        #endif
        return nil
    }

    /// context の続きを予測する。新しい要求が来て打ち切られた場合や、自信度が足りない場合は nil。
    /// minLogProb: 自信度の下限（nil なら既定の -0.7。何も入力していない状態では緩めて出やすくする）
    /// prefix: 文脈の前に固定で置く文章（場面学習の本人の文の手本。同じ文章の間は計算を使い回す）
    /// leadingPunctuation: 予測の頭の句読点を許すか（nil なら、minLogProb を指定したとき＝何も入力していない状態だけ許す）
    // 呼び出し側のactor上で取消番号とキュー投入を確定してから待つ。
    // マイクの確認後にexecutorを移って、既に取消された生成を新しく登録し直さない。
    public func complete(context: String, minLogProb: Float? = nil, leadingPunctuation: Bool? = nil, prefix: String = "", reference: String = "", isolation: isolated (any Actor)? = #isolation) async -> Suggestion? {
        let id = self.lock.withLock {
            self.latestRequestID &+= 1
            return self.latestRequestID
        }
        return await withCheckedContinuation { continuation in
            self.queue.async {
                continuation.resume(returning: self.run(
                    context: context, id: id, minLogProb: minLogProb, leadingPunctuation: leadingPunctuation ?? (minLogProb != nil), prefix: prefix, reference: reference
                ))
            }
        }
    }

    /// 何も入力していないときの「書き進める」補完: context の続きを 1 文生成する（改行・段落の区切りを含みうる）。
    public func continueSentence(context: String, prefix: String = "", reference: String = "", isolation: isolated (any Actor)? = #isolation) async -> String? {
        let id = self.lock.withLock {
            self.latestRequestID &+= 1
            return self.latestRequestID
        }
        return await withCheckedContinuation { continuation in
            self.queue.async {
                continuation.resume(returning: self.runSentence(context: context, id: id, prefix: prefix, reference: reference))
            }
        }
    }

    private func runSentence(context: String, id: UInt64, prefix: String, reference: String) -> String? {
        #if canImport(Gemma4ANE)
        guard #available(macOS 15.0, *) else {
            return nil
        }
        guard !self.isStale(id), let completer = self.loadedCompleter() else {
            return nil
        }
        guard !self.isStale(id), self.preemption.enter() else { return nil }
        defer { self.preemption.leave(); self.scheduleUnload() }
        let prefix = WindowReferencePrompt.prefix(reference: reference, personal: prefix, encode: completer.encodeContext, decode: completer.decodeContext)
        let result = try? autoreleasepool(invoking: {
            try InferenceActivity.measure(feature: "idle-sentence", device: "ANE") { try completer.continueSentence(context: context, prefix: prefix, isCancelled: { self.isStale(id) }) }
        })
        guard let result, WindowReferenceGeneration.permits(result, draft: context, reference: reference) else { return nil }
        return result
        #else
        return nil
        #endif
    }

    /// モデルを先に読み込んでおく（設定を有効にしたときなど）。
    public func preload() {
        #if canImport(Gemma4ANE)
        self.queue.async {
            if #available(macOS 15.0, *) {
                _ = self.loadedCompleter()
            }
        }
        #endif
    }

    #if canImport(Gemma4ANE)
    @available(macOS 15.0, *)
    private func loadedCompleter() -> Gemma4Completer? {
        let directoryURL = Self.modelDirectoryOverride ?? Self.modelDirectoryURL(powerSaving: Config.NextTextCompletionPowerSaving().value)
        if let completer = self.completer as? Gemma4Completer, self.loadedDirectoryURL == directoryURL {
            return completer
        }
        // 設定が変わったら読み直す。読み込みに失敗した直後は繰り返さない
        self.completer = nil
        if let failure = self.lastLoadFailure, Date().timeIntervalSince(failure) < 60 {
            return nil
        }
        do {
            let model = try Gemma4ANEModel(directoryURL: directoryURL)
            let completer = Gemma4Completer(model: model)
            self.completer = completer
            self.loadedDirectoryURL = directoryURL
            self.lastLoadFailure = nil
            return completer
        } catch {
            self.lastLoadFailure = Date()
            return nil
        }
    }

    #endif

    private func scheduleUnload() {
        self.unloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.completer = nil
        }
        self.unloadWorkItem = item
        self.queue.asyncAfter(deadline: .now() + Self.idleUnloadInterval, execute: item)
    }

    private func run(context: String, id: UInt64, minLogProb: Float?, leadingPunctuation: Bool, prefix: String, reference: String) -> Suggestion? {
        #if canImport(Gemma4ANE)
        guard #available(macOS 15.0, *) else {
            return nil
        }
        guard !self.isStale(id), let completer = self.loadedCompleter() else {
            return nil
        }
        guard !self.isStale(id), self.preemption.enter() else { return nil }
        defer { self.preemption.leave(); self.scheduleUnload() }
        let start = Date()
        do {
            completionRuns &+= 1
            completer.options.minLogProb = minLogProb ?? Self.defaultMinLogProb
            // 何も入力していない状態（自信度の下限を緩めた要求）だけ、予測の頭の句読点を許す
            let prefix = WindowReferencePrompt.prefix(reference: reference, personal: prefix, encode: completer.encodeContext, decode: completer.decodeContext)
            completer.options.leadingPunctuation = leadingPunctuation
            guard let result = try autoreleasepool(invoking: {
                try InferenceActivity.measure(feature: leadingPunctuation ? "idle" : "completion", device: "ANE") { try completer.complete(context: context, prefix: prefix, isCancelled: { self.isStale(id) }) }
            }) else {
                return nil
            }
            guard WindowReferenceGeneration.permits(result.text, draft: context, reference: reference) else { return nil }
            return Suggestion(text: result.text, confidence: result.minLogProb, elapsedMilliseconds: Date().timeIntervalSince(start) * 1000)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

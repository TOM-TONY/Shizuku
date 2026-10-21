import Foundation

/// llm-ime: 文章の続き（次に入力しそうな文字列）を予測する。
///
/// 前回の入力と先頭が一致する部分の KV キャッシュを使い回し、変わった部分だけを計算する。
/// 打鍵のたびに文脈の末尾だけが変わるので、通常は数トークン分の計算で済む。
/// 候補は最初の句読点（含む）まで・最大 maxCharacters 文字。対数確率がしきい値を下回るトークンが
/// 出たらその手前で切る（2 文字未満なら候補なし）。1 つでも下回ったら候補ごと捨てる方式より、
/// 出せる候補が多い。
///
/// 文脈は入力途中の語で終わることが多く、そのままトークン化すると学習時に現れない区切り
/// （例:「致し」で終わる）になって予測が崩れる。そこで文脈の最後のトークンを外し、最初の生成を
/// 「外した文字列と矛盾しないトークン」に限る（token healing）。
@available(macOS 15.0, *)
public final class Gemma4Completer: @unchecked Sendable {
    public struct Options: Sendable {
        public var maxCharacters: Int = 12
        public var maxTokens: Int = 12
        /// 自信度（候補を作るトークンの対数確率の最小値）の下限
        public var minLogProb: Float = -0.7
        /// true: 自信度が下限を割ったトークンの手前までを候補にする（minCharacters 以上なら）。
        /// false: 1 つでも下限を割ったら候補を出さない
        public var truncateAtLowConfidence = true
        public var minCharacters: Int = 2
        /// 文脈の最後のトークンを外して生成し直す（token healing）
        public var tokenHealing = true
        /// token healing で調べる上位候補の数
        public var healingCandidates = 64
        /// 文脈として使う最大トークン数（nil なら KV キャッシュ長 - 生成分）
        public var maxContextTokens: Int?
        /// true: 予測の頭の句読点では切らず、句読点だけのトークンは自信の判定に数えない（何も入力していない状態用。
        /// 「本日はお忙しいところ」→「、お越し…」）。入力中の予測では、頭の句読点を許すと外れが増える
        /// ため false
        public var leadingPunctuation = false
        /// 文脈が長すぎるときに古い方から削る単位（トークン）。打鍵ごとに 1 つずつずらすと、先頭が変わって
        /// KV キャッシュを使い回せず毎回全部計算し直すことになるため、まとめてずらす
        public var contextSlideStep: Int = 64
        /// この数以下の新規トークンは infer で 1 つずつ、超えたら prefill でまとめて入力する
        public var inferThreshold: Int = 3
        public init() {}
    }

    public struct Suggestion: Sendable, Equatable {
        public var text: String
        public var minLogProb: Float
        public var tokenCount: Int
    }

    /// 生成した 1 トークン分（自己調整で、しきい値を変えた結果を後から求める）
    public struct Piece: Sendable, Equatable {
        public var text: String
        public var logProb: Float
        /// 句読点だけのトークン（何も入力していないときの補完では自信の判定に数えない）
        public var isPunctuationOnly: Bool

        public init(text: String, logProb: Float, isPunctuationOnly: Bool) {
            self.text = text
            self.logProb = logProb
            self.isPunctuationOnly = isPunctuationOnly
        }
    }

    /// しきい値を最も緩くして（足切りなし）続きを生成し、トークンごとの対数確率を返す。候補の長さの上限・句読点で止める
    /// 規則は complete と同じ。しきい値 t の候補は、対数確率が t を下回る最初のトークンの手前まで（`Self.suggestion(from:threshold:)`）
    public func completePieces(context: String, prefix: String = "", isCancelled: () -> Bool = { false }) throws -> [Piece] {
        let saved = self.options
        defer {
            self.options = saved
        }
        self.options.minLogProb = -.infinity
        self.options.truncateAtLowConfidence = true
        var pieces: [Piece] = []
        _ = try self.complete(context: context, prefix: prefix, isCancelled: isCancelled, onPiece: { piece in
            pieces.append(piece)
        })
        return pieces
    }

    /// トークンごとの記録から、しきい値 threshold のときに出す候補（出さなければ nil）。complete と同じく句読点まで・最大文字数
    public static func suggestion(from pieces: [Piece], threshold: Float, maxCharacters: Int = 12, minCharacters: Int = 2) -> String? {
        var text = ""
        for piece in pieces {
            if piece.logProb < threshold {
                break
            }
            text += piece.text
        }
        var suggestion = ""
        var hasContent = false
        for ch in text {
            if ch == "\n" {
                break
            }
            suggestion.append(ch)
            if Self.punctuation.contains(ch) || suggestion.count >= maxCharacters {
                break
            }
            if !ch.isWhitespace {
                hasContent = true
            }
        }
        guard suggestion.count >= minCharacters, hasContent, !suggestion.contains(where: Self.rejected.contains) else {
            return nil
        }
        return suggestion
    }

    public enum Stop: Error {
        case cancelled
    }

    public let model: Gemma4ANEModel
    /// KV キャッシュに入っているトークン（位置 0 から）
    private var cached: [Int32] = []
    /// cached の最後のトークンを入力したあとの hidden
    private var lastHidden: [Float16]?

    private static let punctuation: Set<Character> = ["、", "。", "！", "？", "!", "?"]
    private static let rejected: Set<Character> = ["<", ">", "[", "]", "*", "#", "`", "{", "}", "|", "\\"]

    // MARK: - 書き進める補完（何も入力していないとき）

    private static let sentenceEnd: Set<Character> = ["。", "！", "？", "!", "?"]

    /// 空白・句読点以外の文字を含むか
    static func hasContent(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace && !Self.punctuation.contains($0) }
    }

    /// 次のトークン（token healing 中は外した文字列と矛盾しないものの中で正規化した対数確率）
    private func nextToken(hidden: [Float16], pending: [UInt8]) throws -> (Gemma4ANEModel.Prediction, Float)? {
        let tokenizer = self.model.tokenizer
        if pending.isEmpty {
            return try self.model.topTokens(hidden: hidden).first.map { ($0, $0.logProb) }
        }
        let consistent = try self.model.topTokens(hidden: hidden, k: self.options.healingCandidates).filter {
            guard !tokenizer.specialIDs.contains($0.token) else {
                return false
            }
            let b = tokenizer.bytes([$0.token])
            return !b.isEmpty && (b.starts(with: pending) || pending.starts(with: b))
        }
        guard let top = consistent.first else {
            return nil
        }
        return (top, top.logProb - log(consistent.reduce(Float(0)) { $0 + exp($1.logProb) }))
    }

    /// 文章を書き進めるための補完: context の続きを 1 文（文末の 。！？ か改行まで）生成する。改行・空行（段落の区切り）
    /// で始まってもよい。自信による足切りはせず、極端に確率の低い語（abortLogProb 未満、約 1%）が出たらその手前で止める
    /// （最初の語から極端に低ければ nil）。続けて呼ぶと、前の結果を足した文脈の KV キャッシュを使い回す
    public func continueSentence(
        context: String,
        prefix: String = "",
        maxTokens: Int = 64,
        abortLogProb: Float = -4.6,
        noRepeatNGram: Int = 8,
        repetitionPenalty: RepetitionPenalty? = .init(),
        isCancelled: () -> Bool = { false },
        trace: ((String) -> Void)? = nil
    ) throws -> String? {
        let tokenizer = self.model.tokenizer
        let prefixIDs = self.prefixTokens(prefix)
        var ids = tokenizer.encode(context)
        let limit = self.model.contextLength - maxTokens - 2 - prefixIDs.count
        let budget = min(self.options.maxContextTokens ?? limit, limit)
        if ids.count > budget {
            let step = max(1, min(self.options.contextSlideStep, budget / 2))
            let drop = (ids.count - budget + step - 1) / step * step
            ids.removeFirst(min(drop, ids.count))
        }
        var tokens = [tokenizer.bos] + prefixIDs + ids
        var pending: [UInt8] = []
        if self.options.tokenHealing, !ids.isEmpty {
            pending = tokenizer.bytes([tokens.removeLast()])
        }
        var newBytes: [UInt8] = []
        var text = ""
        var endedNaturally = false
        // 繰り返しを防ぐ: 文脈にすでにある n-gram（トークン n 個の並び）を作る候補は選ばない
        // （貪欲に選ぶと同じ文を何度も繰り返しやすい）。n が小さいと「量子力学」のような語そのものの繰り返しまで
        // 禁じて文が崩れるため、文まるごとの繰り返しだけを防ぐ長さ（8）にする
        let n = max(2, noRepeatNGram)
        var seenNext: [[Int32]: Set<Int32>] = [:]
        func register(at end: Int) {
            guard end >= n else {
                return
            }
            seenNext[Array(tokens[end - n..<end - 1]), default: []].insert(tokens[end - 1])
        }
        for end in stride(from: n, through: tokens.count, by: 1) {
            register(at: end)
        }
        for _ in 0..<maxTokens {
            let hidden = try self.advance(to: tokens, isCancelled: isCancelled)
            if isCancelled() {
                throw Stop.cancelled
            }
            let picked: (Gemma4ANEModel.Prediction, Float)?
            if pending.isEmpty, tokens.count >= n - 1 {
                let blocked = seenNext[Array(tokens.suffix(n - 1))] ?? []
                let top = try self.model.topTokens(hidden: hidden, k: 16)
                // 文脈の並びをなぞり続ける候補を下げて選ぶ（打ち切りの判定はモデル本来の確率で行う）
                let candidates = top.filter { !blocked.contains($0.token) }
                let scored = candidates.map { prediction in
                    (prediction, prediction.logProb - (repetitionPenalty?.penalty(tokens: tokens, candidate: prediction.token) ?? 0))
                }
                if let trace {
                    trace(scored.prefix(5).map { "\(tokenizer.decode([$0.0.token]).debugDescription)\(String(format: "%.2f/%.2f", $0.0.logProb, $0.1))" }.joined(separator: " "))
                }
                var choice = scored.max { $0.1 < $1.1 }?.0
                // 下げた結果、確率の低い候補しか残らない（「シュレディンガー|方程式」のような語の途中で、言い換えようがない）
                // ときは、下げずにモデルの第 1 候補を選ぶ（なぞるのは 8 トークン未満に限られる）
                if let current = choice, current.logProb < abortLogProb, let first = candidates.first, first.logProb >= abortLogProb {
                    choice = first
                }
                picked = choice.map { ($0, $0.logProb) }
            } else {
                picked = try self.nextToken(hidden: hidden, pending: pending)
            }
            guard let (best, logProb) = picked else {
                return nil
            }
            if tokenizer.specialIDs.contains(best.token) {
                endedNaturally = true
                break
            }
            if logProb < abortLogProb {
                if Self.hasContent(text) {
                    break
                }
                return nil
            }
            var bytes = tokenizer.bytes([best.token])
            if !pending.isEmpty {
                if bytes.starts(with: pending) {
                    bytes.removeFirst(pending.count)
                    pending = []
                } else {
                    pending.removeFirst(bytes.count)
                    bytes = []
                }
            }
            tokens.append(best.token)
            register(at: tokens.count)
            newBytes += bytes
            text = tokenizer.string(fromBytes: newBytes)
            if Self.hasContent(text) {
                if let last = text.last, Self.sentenceEnd.contains(last) {
                    endedNaturally = true
                    break
                }
                if text.hasSuffix("\n") {
                    endedNaturally = true
                    break
                }
            }
        }
        // 文の途中で止まった（確率の低い語・長さの上限）場合は、直前の読点までに戻す。なければ出さない
        if !endedNaturally {
            guard let comma = text.lastIndex(where: { $0 == "、" || $0 == "，" || $0 == "," }),
                  Self.hasContent(String(text[...comma])) else {
                return nil
            }
            text = String(text[...comma])
        }
        // 末尾の空白・改行は落とす（次の文の頭で改行を予測し直す）。先頭の改行（段落の区切り）は残す
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
        guard Self.hasContent(text), !text.contains(where: Self.rejected.contains) else {
            return nil
        }
        return text
    }

    /// DRY（Don't Repeat Yourself）方式の繰り返しの抑制。候補を選ぶと文脈のどこかの並びを allowedLength トークンより長く
    /// なぞることになる場合、なぞる長さに応じて指数的に下げる（短い語句の繰り返しは許し、文の丸写しを防ぐ）
    public struct RepetitionPenalty: Sendable {
        public var allowedLength = 2
        public var base: Float = 1.75
        public var multiplier: Float = 0.8
        public var maxLength = 24

        public init(allowedLength: Int = 2, base: Float = 1.75, multiplier: Float = 0.8) {
            self.allowedLength = allowedLength
            self.base = base
            self.multiplier = multiplier
        }

        /// tokens の後に candidate を置いたとき、文脈の同じ並びをなぞる長さに応じた対数確率の減点
        public func penalty(tokens: [Int32], candidate: Int32) -> Float {
            let count = tokens.count
            var longest = 0
            for i in 0..<count where tokens[i] == candidate {
                var length = 0
                while length < self.maxLength, i - 1 - length >= 0, tokens[i - 1 - length] == tokens[count - 1 - length] {
                    length += 1
                }
                longest = max(longest, length)
            }
            guard longest >= self.allowedLength else {
                return 0
            }
            return self.multiplier * pow(self.base, Float(longest - self.allowedLength))
        }
    }

    /// 句読点以外の文字のあとに句読点が来たか
    static func endsAtPunctuation(_ text: String) -> Bool {
        var hasContent = false
        for ch in text {
            if Self.punctuation.contains(ch) {
                if hasContent {
                    return true
                }
            } else if !ch.isWhitespace {
                hasContent = true
            }
        }
        return false
    }

    public init(model: Gemma4ANEModel) {
        self.model = model
    }

    /// 文脈の前に固定で置く文章（場面学習の本人の文の手本など）のトークン。文脈の窓をずらしても削らず、同じ文章の間は
    /// KV キャッシュを使い回す（変わったときだけ計算し直す）。文脈の窓が狭くなりすぎないよう、長さに上限を設ける
    private var prefixCache: (text: String, ids: [Int32])?

    public func encodeContext(_ text: String) -> [Int32] { model.tokenizer.encode(text) }
    public func decodeContext(_ ids: [Int32]) -> String { model.tokenizer.decode(ids) }
    public var cachedContextTokenCount: Int { cached.count + (prefixCache?.ids.count ?? 0) }
    public func discardContext() {
        model.resetState(); cached.removeAll(); lastHidden = nil; prefixCache = nil
        interruptedForward = false
    }
    public static let maxPrefixTokens = 192


    private func prefixTokens(_ prefix: String) -> [Int32] {
        guard !prefix.isEmpty else {
            return []
        }
        if let cache = self.prefixCache, cache.text == prefix {
            return cache.ids
        }
        let ids = Array(self.model.tokenizer.encode(prefix).prefix(Self.maxPrefixTokens))
        self.prefixCache = (prefix, ids)
        return ids
    }

    /// 文脈の前に固定で置く文章のトークン数（記録・評価用）
    public func prefixTokenCount(_ prefix: String) -> Int {
        self.prefixTokens(prefix).count
    }

    /// tokens をすべて入力した状態にし、最後の hidden を返す。
    private var interruptedForward = false
    private func advance(to tokens: [Int32], isCancelled: () -> Bool) throws -> [Float16] {
        if interruptedForward {
            self.model.resetState(); self.cached.removeAll(); self.lastHidden = nil
            interruptedForward = false
        }
        var finished = false
        defer { if !finished { interruptedForward = true; self.cached.removeAll(); self.lastHidden = nil } }
        var p = zip(self.cached, tokens).prefix { $0 == $1 }.count
        if p == tokens.count, p == self.cached.count, let h = self.lastHidden {
            finished = true
            return h
        }
        if p == tokens.count {
            p -= 1  // 最後のトークンの hidden を得るため 1 つは計算し直す
        }
        // 以降、cached[0..<p] だけが有効
        self.cached.removeSubrange(p...)
        self.lastHidden = nil
        var hidden: [Float16] = []
        while p < tokens.count {
            if isCancelled() {
                throw Stop.cancelled
            }
            let remaining = tokens.count - p
            if remaining <= self.options.inferThreshold {
                hidden = try self.model.forward(tokens: [tokens[p]], start: p, isCancelled: isCancelled)
                p += 1
            } else {
                // prefill はキャッシュ末尾をはみ出せないので、はみ出す場合は開始位置を前に戻す
                // （戻した分は計算済みのトークンを入れ直すだけで結果は変わらない）
                let start = min(p, self.model.contextLength - self.model.prefillLength)
                let end = min(tokens.count, start + self.model.prefillLength)
                hidden = try self.model.forward(tokens: Array(tokens[start..<end]), start: start, isCancelled: isCancelled)
                p = end
            }
            self.cached = Array(tokens[..<p])
        }
        self.lastHidden = hidden
        finished = true
        return hidden
    }

    public var options = Options()

    /// 文脈 context の続きを予測する。自信度が足りない・候補にならない場合は nil。
    public func complete(context: String, prefix: String = "", isCancelled: () -> Bool = { false }) throws -> Suggestion? {
        try self.complete(context: context, prefix: prefix, isCancelled: isCancelled, onPiece: nil)
    }

    private func complete(
        context: String, prefix: String, isCancelled: () -> Bool, onPiece: ((Piece) -> Void)?
    ) throws -> Suggestion? {
        let tokenizer = self.model.tokenizer
        let prefixIDs = self.prefixTokens(prefix)
        var ids = tokenizer.encode(context)
        let limit = self.model.contextLength - self.options.maxTokens - 2 - prefixIDs.count
        let budget = min(self.options.maxContextTokens ?? limit, limit)
        if ids.count > budget {
            // 文脈の窓をスライドさせる（古い方から contextSlideStep 単位で削る）
            let step = max(1, min(self.options.contextSlideStep, budget / 2))
            let drop = (ids.count - budget + step - 1) / step * step
            ids.removeFirst(min(drop, ids.count))
        }
        var tokens = [tokenizer.bos] + prefixIDs + ids
        // 生成の先頭が満たすべきバイト列（token healing で外した末尾トークン）
        var pending: [UInt8] = []
        if self.options.tokenHealing, !ids.isEmpty {
            pending = tokenizer.bytes([tokens.removeLast()])
        }
        var generated: [Int32] = []
        var newBytes: [UInt8] = []
        var minLogProb: Float = 0
        var text = ""
        for _ in 0..<self.options.maxTokens {
            let hidden = try self.advance(to: tokens, isCancelled: isCancelled)
            if isCancelled() {
                throw Stop.cancelled
            }
            let best: Gemma4ANEModel.Prediction
            let logProb: Float
            if pending.isEmpty {
                guard let top = try self.model.topTokens(hidden: hidden).first else {
                    return nil
                }
                best = top
                logProb = top.logProb
            } else {
                // 外した文字列と矛盾しない候補（それで始まる・その先頭部分になっている）の中で正規化する
                let consistent = try self.model.topTokens(hidden: hidden, k: self.options.healingCandidates).filter {
                    guard !tokenizer.specialIDs.contains($0.token) else {
                        return false
                    }
                    let b = tokenizer.bytes([$0.token])
                    return !b.isEmpty && (b.starts(with: pending) || pending.starts(with: b))
                }
                guard let top = consistent.first else {
                    return nil
                }
                best = top
                logProb = top.logProb - log(consistent.reduce(Float(0)) { $0 + exp($1.logProb) })
            }
            if tokenizer.specialIDs.contains(best.token) {
                break
            }
            var bytes = tokenizer.bytes([best.token])
            var stillPending = pending
            if !stillPending.isEmpty {
                if bytes.starts(with: stillPending) {
                    bytes.removeFirst(stillPending.count)
                    stillPending = []
                } else {
                    stillPending.removeFirst(bytes.count)
                    bytes = []
                }
            }
            // 句読点だけのトークン（読点を打つかどうか）は好みが分かれて確率が低くなりがちなので、自信の判定に数えない
            let piece = tokenizer.string(fromBytes: bytes)
            let isPunctuationOnly = !piece.isEmpty && piece.allSatisfy { Self.punctuation.contains($0) || $0 == " " || $0 == "　" }
            let lenientPunctuation = isPunctuationOnly && self.options.leadingPunctuation
            if logProb < self.options.minLogProb, !lenientPunctuation {
                if self.options.truncateAtLowConfidence {
                    break
                }
                return nil
            }
            if !lenientPunctuation {
                minLogProb = min(minLogProb, logProb)
            }
            onPiece?(Piece(text: piece, logProb: logProb, isPunctuationOnly: isPunctuationOnly))
            pending = stillPending
            generated.append(best.token)
            tokens.append(best.token)
            newBytes += bytes
            text = tokenizer.string(fromBytes: newBytes)
            let reachedPunctuation = self.options.leadingPunctuation
                ? Self.endsAtPunctuation(text)
                : text.contains(where: Self.punctuation.contains)
            if text.contains("\n") || reachedPunctuation || text.count >= self.options.maxCharacters {
                break
            }
        }
        // 句読点以外の文字のあとの最初の句読点（含む）まで、最大 maxCharacters 文字に整える
        // （先頭の句読点では切らない。例:「本日はお忙しいところ」→「、ありがとうございます」）
        var suggestion = ""
        var hasContent = false
        for ch in text {
            if ch == "\n" {
                break
            }
            suggestion.append(ch)
            let isPunctuation = Self.punctuation.contains(ch)
            if isPunctuation && (hasContent || !self.options.leadingPunctuation) || suggestion.count >= self.options.maxCharacters {
                break
            }
            if !isPunctuation && !ch.isWhitespace {
                hasContent = true
            }
        }
        guard suggestion.count >= self.options.minCharacters, hasContent, !suggestion.contains(where: Self.rejected.contains) else {
            return nil
        }
        return Suggestion(text: suggestion, minLogProb: minLogProb, tokenCount: generated.count)
    }
}

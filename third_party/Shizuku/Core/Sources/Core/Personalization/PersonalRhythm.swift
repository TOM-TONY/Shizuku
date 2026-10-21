import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// MARK: - 本人の打鍵のリズム（llm-ime、フェーズ 4）
//
// 何も入力していないとき（入力が空のとき）に手を止めた長さ（前のキーから次のキーまで）を、場面・アプリ・全体の段ごとに
// ヒストグラムで数える。迷いの検知（放置で続きを出すまでの待ち時間を、本人がいつもより長く止まったときにする）で使う。
// 数えるのは長さだけで、文章は含まない。

public enum PersonalRhythm {
    /// IME 本体の既定の待ち時間（ShizukuInputController.idleCompletionDelay と同じ）
    public static let fixedIdleDelay = 3.0
    /// 数える手の止め方の範囲（これより長いのは席を外したとみなして数えない）
    public static let minimumPause = 0.05
    public static let maximumPause = 60.0
    /// ヒストグラムの区切り: 0.1 秒から 1.12 倍ずつ 60 秒まで
    static let firstEdge = 0.1
    static let ratio = 1.12
    public static let bucketCount = Int((log(Self.maximumPause / Self.firstEdge) / log(Self.ratio)).rounded(.up)) + 1
    /// 数が多くなったら半分にする（古いリズムを薄める）
    static let halveAbove = 4000
    /// 本人のリズムを使うのに要る、手を止めた回数（それまでは決まった秒数）
    public static let minimumPauses = 200
    /// 本人のリズムで待つ長さの範囲（秒）
    public static let delayRange = 1.5...6.0
    /// いつもより長く止まった: 手を止めた長さの 9 割より長い
    public static let defaultQuantile = 0.9

    public struct Histogram: Codable, Equatable, Sendable {
        public var counts: [Int]
        public var total: Int
        public var updated: Double

        public init() {
            self.counts = Array(repeating: 0, count: PersonalRhythm.bucketCount)
            self.total = 0
            self.updated = 0
        }
    }

    /// i 番目の区切りの下端（秒）
    static func lowerEdge(_ index: Int) -> Double {
        index == 0 ? 0 : Self.firstEdge * pow(Self.ratio, Double(index - 1))
    }

    static func upperEdge(_ index: Int) -> Double {
        Self.firstEdge * pow(Self.ratio, Double(index))
    }

    static func bucket(_ seconds: Double) -> Int {
        guard seconds >= Self.firstEdge else {
            return 0
        }
        let index = Int(floor(log(seconds / Self.firstEdge) / log(Self.ratio))) + 1
        return min(max(index, 0), Self.bucketCount - 1)
    }

    /// 手を止めた長さを 1 つ足す（範囲外は数えない）。足したら true
    @discardableResult
    public static func add(_ histogram: inout Histogram, seconds: Double, now: Double) -> Bool {
        guard seconds >= Self.minimumPause, seconds <= Self.maximumPause else {
            return false
        }
        if histogram.counts.count != Self.bucketCount {
            histogram = Histogram()
        }
        histogram.counts[Self.bucket(seconds)] += 1
        histogram.total += 1
        histogram.updated = now
        if histogram.total > Self.halveAbove {
            histogram.counts = histogram.counts.map { $0 / 2 }
            histogram.total = histogram.counts.reduce(0, +)
        }
        return true
    }

    /// 本人のリズムで待つ長さ: 細かい段から順に、手を止めた回数が足りる最初の段の分位（範囲に収める）。足りる段がなければ nil
    public static func personalDelay(histograms: [Histogram?], quantile q: Double) -> Double? {
        for histogram in histograms {
            if let histogram, histogram.total >= Self.minimumPauses, let value = Self.quantile(histogram, q) {
                return min(max(value, Self.delayRange.lowerBound), Self.delayRange.upperBound)
            }
        }
        return nil
    }

    /// q 分位（0〜1）の長さ（秒）。区切りの中は対数で補間する。数がなければ nil
    public static func quantile(_ histogram: Histogram, _ q: Double) -> Double? {
        guard histogram.total > 0 else {
            return nil
        }
        let target = q * Double(histogram.total)
        var cumulative = 0.0
        for (index, count) in histogram.counts.enumerated() where count > 0 {
            let next = cumulative + Double(count)
            if next >= target {
                let fraction = (target - cumulative) / Double(count)
                let low = max(Self.lowerEdge(index), Self.minimumPause)
                let high = Self.upperEdge(index)
                return low * pow(high / low, min(max(fraction, 0), 1))
            }
            cumulative = next
        }
        return Self.upperEdge(Self.bucketCount - 1)
    }
}

// MARK: - 言い直し（llm-ime、フェーズ 4）
//
// 確定した直後にアプリでバックスペースを押して消し、別の語句を書いた対（消した語句 → 書き直した語句）。

public enum PersonalRewrite {
    /// 確定の直後に、バックスペース backspaces 回で消した部分（確定後の左文脈 afterCommit の末尾）。
    /// 次のキーの時点の左文脈が分かっていて、消した残りと合わなければ（カーソルを動かした・別の所を消した）nil
    public static func deletedSpan(afterCommit: String, backspaces: Int, leftContextNow: String?) -> String? {
        guard backspaces > 0, backspaces <= afterCommit.count else {
            return nil
        }
        let remaining = afterCommit.dropLast(backspaces)
        if let left = leftContextNow, !left.isEmpty {
            guard left.hasSuffix(String(remaining.suffix(8))) else {
                return nil
            }
        }
        return String(afterCommit.suffix(backspaces))
    }

    /// 書き直した語句ごとの回数と読み（カタカナ。分からなければ nil）
    public struct Tally: Codable, Equatable, Sendable {
        public var count: Int
        public var reading: String?

        public init(count: Int, reading: String?) {
            self.count = count
            self.reading = reading
        }
    }

    /// 出すのに要る、同じ言い直しの回数（自己調整で場面ごとに 2 まで下げることがある）
    public static let defaultRepeats = 3
    /// 消した語句の長さの下限（1 文字の直しは打ち間違いに近い）
    public static let minimumDeletedLength = 2

    /// 入力中の第 1 候補 deleted に対して出す、書き直した語句（出さなければ nil）。
    /// 同じ言い直しを repeats 回以上見ていて、ほかの書き直しより多く、読みが分かっていて今の読みと違う（同じ読みは選択学習が受け持つ）とき
    public static func suggestion(
        deleted: String, tallies: [String: Tally]?, ignores: Int, repeats: Int, currentReading: String
    ) -> String? {
        guard deleted.count >= Self.minimumDeletedLength, let tallies else {
            return nil
        }
        let ranked = tallies.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        guard let top = ranked.first, top.value.count >= repeats, top.key != deleted,
              top.value.count > (ranked.dropFirst().first?.value.count ?? 0),
              let reading = top.value.reading, !reading.isEmpty,
              reading.toKatakana() != currentReading.toKatakana() else {
            return nil
        }
        return top.key
    }

    /// 記録する価値のある対か（同じものを打ち直しただけ・長すぎる・秘密らしいものは記録しない）
    public static func isWorthRecording(deleted: String, written: String) -> Bool {
        let deleted = deleted.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deleted.isEmpty, !written.isEmpty, deleted != written, deleted.count <= 20, written.count <= 60 else {
            return false
        }
        return deleted.range(of: #"\p{Nd}{4,}"#, options: .regularExpression) == nil
            && !PersonalPrivacy.looksSecret(deleted) && !PersonalPrivacy.looksSecret(written)
    }
}

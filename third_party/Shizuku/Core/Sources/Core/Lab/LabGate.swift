import Foundation

// MARK: - 採否の答え合わせ（llm-ime、解析と学習 段階 A）
//
// 案ごとに、取り置き分の同じ項目を今の版と案で評価し、項目ごとの差（案 − 今）を取る。日ごとにまとめて復元抽出する
// ブートストラップ（2000 回、乱数の種は決まった値）で、差の平均の 95% 区間を求める。主な指標の下限が 0 より上で、
// ほかの指標の下限が「悪くならない幅」（−δ）より上のときだけ採用する。種が決まっているので、ShizukuLab と ConverterServer が
// 同じ項目から同じ判定を出す（ConverterServer は ShizukuLab の判定を信じず、項目ごとの差から計算し直す）。

public enum LabGate {
    /// 1 項目の差（指標 → 案 − 今。その項目で測れない指標は入れない）。day は日ごとのまとまり（ブートストラップの単位）
    public struct Item: Codable, Equatable, Sendable {
        public var day: Int
        public var diffs: [String: Double]

        public init(day: Int, diffs: [String: Double]) {
            self.day = day
            self.diffs = diffs
        }
    }

    /// 指標の決まり。primary なら下限が 0 より上、そうでなければ下限が −margin より上（悪くならない）
    public struct Rule: Codable, Equatable, Sendable {
        public var metric: String
        public var primary: Bool
        public var margin: Double

        public init(metric: String, primary: Bool, margin: Double) {
            self.metric = metric
            self.primary = primary
            self.margin = margin
        }
    }

    public struct Interval: Codable, Equatable, Sendable {
        public var mean: Double
        public var lower: Double
        public var upper: Double
        public var count: Int
    }

    public struct Decision: Codable, Equatable, Sendable {
        public var accepted: Bool
        public var intervals: [String: Interval]
        public var reasons: [String]
    }

    public static let resamples = 2000

    /// 決まった種の乱数（SplitMix64）
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var z = self.state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func next(below bound: Int) -> Int {
            Int(self.next() % UInt64(bound))
        }
    }

    /// 指標の差の平均と、日ごとのブートストラップの 95% 区間（測れる項目がなければ nil）
    public static func interval(items: [Item], metric: String, seed: UInt64, resamples: Int = Self.resamples) -> Interval? {
        var byDay: [Int: (sum: Double, count: Int)] = [:]
        for item in items {
            guard let diff = item.diffs[metric] else {
                continue
            }
            byDay[item.day, default: (0, 0)].sum += diff
            byDay[item.day, default: (0, 0)].count += 1
        }
        let days = byDay.keys.sorted().map { byDay[$0]! }
        let total = days.reduce(0) { $0 + $1.count }
        guard total > 0 else {
            return nil
        }
        let mean = days.reduce(0) { $0 + $1.sum } / Double(total)
        var random = Random(state: seed ^ UInt64(truncatingIfNeeded: metric.hashValueStable))
        var means: [Double] = []
        means.reserveCapacity(resamples)
        for _ in 0..<resamples {
            var sum = 0.0
            var count = 0
            for _ in 0..<days.count {
                let day = days[random.next(below: days.count)]
                sum += day.sum
                count += day.count
            }
            means.append(count == 0 ? 0 : sum / Double(count))
        }
        means.sort()
        let lower = means[Int(Double(resamples) * 0.025)]
        let upper = means[min(resamples - 1, Int(Double(resamples) * 0.975))]
        return Interval(mean: mean, lower: lower, upper: upper, count: total)
    }

    /// 採否。主な指標が 1 つ以上あり、すべての決まりを満たすときだけ採用する
    public static func decide(items: [Item], rules: [Rule], seed: UInt64) -> Decision {
        var intervals: [String: Interval] = [:]
        var reasons: [String] = []
        var accepted = rules.contains(where: \.primary)
        for rule in rules {
            guard let interval = Self.interval(items: items, metric: rule.metric, seed: seed) else {
                if rule.primary {
                    accepted = false
                    reasons.append("\(rule.metric): 測れる項目がない")
                }
                continue
            }
            intervals[rule.metric] = interval
            if rule.primary, interval.lower <= 0 {
                accepted = false
                reasons.append(String(format: "%@: 良くなったとは言えない（下限 %.4f）", rule.metric, interval.lower))
            } else if !rule.primary, interval.lower <= -rule.margin {
                accepted = false
                reasons.append(String(format: "%@: 悪くなるおそれ（下限 %.4f、許す幅 −%.4f）", rule.metric, interval.lower, rule.margin))
            }
        }
        return Decision(accepted: accepted, intervals: intervals, reasons: reasons)
    }
}

extension String {
    /// 実行ごとに変わらない文字列の値（FNV-1a）。Swift の hashValue は実行ごとに変わるので、種には使わない
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in self.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return hash
    }
}

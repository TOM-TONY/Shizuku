import Foundation

public enum LabMagic {
    public static func eligible(_ row: LabCommit) -> Bool {
        row.isMaterial && ["selection", "enter", "transform", "ai"].contains(row.kind)
            && row.reading.map { !$0.isEmpty && $0.count <= 80 && !PersonalPrivacy.looksSecret($0) } == true
            && !row.surface.isEmpty && row.surface.count <= 80 && !PersonalPrivacy.looksSecret(row.surface)
            && PersonalScene(key: row.scene) != nil
    }
    /// 日付順に均等に選び、同じ組を毎回使う。答えの良し悪しで項目を選ばない。
    public static func samples(_ rows: [LabCommit], limit: Int = 96) -> [LabCommit] {
        let rows = rows.filter(eligible)
        guard rows.count > limit else { return rows }
        return (0..<limit).map { rows[$0 * rows.count / limit] }
    }
    public static func f1(_ predicted: String, _ actual: String) -> Double {
        Self.f1(Self.Fingerprint(predicted), Self.Fingerprint(actual))
    }

    /// 上限の全探索では同じ過去文を何度も比べる。字句の数え方は通常の F1 と共有する。
    public struct Fingerprint: Sendable {
        let grams: [String: Int]
        let total: Int

        public init(_ s: String) {
            let chars = Array(s.precomposedStringWithCompatibilityMapping)
            var result: [String: Int] = [:]
            if chars.count < 2 {
                result = s.isEmpty ? [:] : [s: 1]
            } else {
                for i in 0..<(chars.count - 1) { result[String(chars[i...i+1]), default: 0] += 1 }
            }
            self.grams = result
            self.total = result.values.reduce(0, +)
        }
    }

    public static func f1(_ predicted: Fingerprint, _ actual: Fingerprint) -> Double {
        let total = predicted.total + actual.total
        guard total > 0 else { return 1 }
        let (small, large) = predicted.grams.count <= actual.grams.count ? (predicted.grams, actual.grams) : (actual.grams, predicted.grams)
        return 2 * Double(small.reduce(0) { $0 + min($1.value, large[$1.key, default: 0]) }) / Double(total)
    }
}

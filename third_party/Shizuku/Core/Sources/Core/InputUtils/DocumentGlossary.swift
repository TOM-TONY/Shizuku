import Foundation
import KanaKanjiConverterModule

/// llm-ime: 同じ入力欄の、カーソルより前の文章に書いてある表記を、変換候補の先頭に置く。
/// 変換に渡す左文脈は 40 字なので、それより前に書いた語（「船底」など）は zenz からは見えない。
/// Client が送る左文脈（最大 2000 字）だけを使い、保存しない。候補を作ったり点数を変えたりはしない。
/// 第 1 候補がすでに文章に書いてある表記なら動かさない（同じ読みの語を 2 つ書いている文章では、変換の判断に任せる）。
public enum DocumentGlossary {
    /// 先頭に上げる候補を探す範囲（元の順位）
    public static let searchDepth = 20

    /// whole は、候補が読み全体の候補か（一部だけの候補は動かさない）
    public static func promote(_ candidates: [Candidate], document: String, whole: (Candidate) -> Bool) -> [Candidate] {
        guard candidates.count > 1, !document.isEmpty else {
            return candidates
        }
        func written(_ candidate: Candidate) -> Bool {
            whole(candidate) && isDistinctive(candidate.text) && document.contains(candidate.text)
        }
        let depth = min(searchDepth, candidates.count)
        guard !written(candidates[0]),
              let index = (1..<depth).first(where: { written(candidates[$0]) }) else {
            return candidates
        }
        var result = candidates
        result.insert(result.remove(at: index), at: 0)
        return result
    }

    /// 2 字以上で、漢字かカタカナを含む表記。「こと」「です」のような語が偶然文章にあるだけでは並びを変えない
    static func isDistinctive(_ text: String) -> Bool {
        text.count >= 2 && text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x30A1...0x30FA: true
            default: false
            }
        }
    }
}

import Foundation

/// llm-ime: 添削・書き直しの結果を「変更箇所」ごとに扱うための文字単位の差分。
public struct TextDiffHunk: Sendable, Equatable, Identifiable {
    /// 元の文の中の位置（Character 単位）
    public var originalRange: Range<Int>
    public var originalText: String
    public var replacement: String

    public var id: String { "\(originalRange.lowerBound)-\(originalRange.upperBound)-\(replacement)" }

    public init(originalRange: Range<Int>, originalText: String, replacement: String) {
        self.originalRange = originalRange
        self.originalText = originalText
        self.replacement = replacement
    }
}

public enum TextDiff {
    /// original を revised にする変更箇所の一覧（隣り合う変更はまとめる）。
    public static func hunks(from original: String, to revised: String) -> [TextDiffHunk] {
        let a = Array(original), b = Array(revised)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _):
                removed.insert(offset)
            case .insert(let offset, _, _):
                inserted.insert(offset)
            }
        }
        var hunks: [TextDiffHunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            let start = i, insertStart = j
            while i < a.count, removed.contains(i) {
                i += 1
            }
            while j < b.count, inserted.contains(j) {
                j += 1
            }
            if start == i, insertStart == j {
                // 念のため（差分と整合しない場合に止まらないように）
                i += 1
                j += 1
                continue
            }
            let hunk = TextDiffHunk(originalRange: start..<i, originalText: String(a[start..<i]), replacement: String(b[insertStart..<j]))
            if let last = hunks.last, last.originalRange.upperBound == start {
                hunks[hunks.count - 1] = TextDiffHunk(
                    originalRange: last.originalRange.lowerBound..<i,
                    originalText: last.originalText + hunk.originalText,
                    replacement: last.replacement + hunk.replacement
                )
            } else {
                hunks.append(hunk)
            }
        }
        return hunks
    }

    /// 空白（改行を含む）だけの違い。添削では提案しない
    public static func isWhitespaceOnly(_ hunk: TextDiffHunk) -> Bool {
        hunk.originalText.filter { !$0.isWhitespace } == hunk.replacement.filter { !$0.isWhitespace }
    }

    /// original に、選んだ変更箇所だけを適用する。
    public static func apply(_ hunks: [TextDiffHunk], to original: String) -> String {
        let a = Array(original)
        var result = ""
        var position = 0
        for hunk in hunks.sorted(by: { $0.originalRange.lowerBound < $1.originalRange.lowerBound }) {
            guard hunk.originalRange.lowerBound >= position, hunk.originalRange.upperBound <= a.count else {
                continue
            }
            result += String(a[position..<hunk.originalRange.lowerBound])
            result += hunk.replacement
            position = hunk.originalRange.upperBound
        }
        result += String(a[position...])
        return result
    }
}

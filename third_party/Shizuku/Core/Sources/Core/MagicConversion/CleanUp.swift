import Foundation

/// llm-ime: 直前の文の清書の切り出しと、出してよい結果かの検査。
/// 本人が打っていない事実を足さない・全文を置き換えたように見せない・差がなければ出さない。
public enum CleanUp {
    public static let maximumLength = 200
    static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
    static let closers: Set<Character> = ["」", "』", "）", ")", "]", "】", "〉", "》"]
    static let openers: Set<Character> = ["「", "『", "（", "(", "[", "【", "〈", "《"]

    /// カーソルの直前の 1 文（文末記号と閉じ括弧を含む）。前の文の文末より後ろから。
    /// 末尾の空白・改行は含めない。2 字未満・200 字を超える文は対象にしない
    public static func lastSentence(_ left: String) -> (sentence: String, before: String)? {
        var chars = Array(left)
        while let last = chars.last, last.isWhitespace { chars.removeLast() }
        guard !chars.isEmpty else { return nil }
        var end = chars.count - 1
        while end > 0, closers.contains(chars[end]) { end -= 1 }
        // 末尾の文末記号は今の文に含め、その前の文末を探す（括弧の中の文末は区切りにしない）
        var index = sentenceEnds.contains(chars[end]) ? end - 1 : end
        var depth = 0
        while index >= 0 {
            let char = chars[index]
            if closers.contains(char) { depth += 1 }
            else if openers.contains(char) { depth = max(0, depth - 1) }
            else if depth == 0, sentenceEnds.contains(char) { break }
            index -= 1
        }
        var start = index + 1
        while start < chars.count, chars[start].isWhitespace { start += 1 }
        guard start < chars.count else { return nil }
        let sentence = String(chars[start...])
        guard sentence.count >= 2, sentence.count <= maximumLength else { return nil }
        return (sentence, String(chars[..<start]))
    }

    static func digitRuns(_ text: String) -> [String] {
        var runs: [String] = [], current = ""
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) { current.unicodeScalars.append(scalar) }
            else if !current.isEmpty { runs.append(current); current = "" }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// 出してよい清書なら、その文（前後の空白を落としたもの）。出さないなら nil
    public static func accept(original: String, result raw: String) -> String? {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["文章:", "文章：", "清書:", "清書："] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !result.isEmpty, result != original else { return nil }
        // 長さが大きく変わった結果（説明・要約・付け足し）は出さない
        let lower = Double(original.count) * 0.5, upper = Double(original.count) * 1.5 + 4
        guard Double(result.count) >= lower, Double(result.count) <= upper else { return nil }
        // 元にない数字（日時・数量）を足した結果は出さない
        let known = Set(digitRuns(original))
        guard digitRuns(result).allSatisfy({ known.contains($0) }) else { return nil }
        // 空白だけの差は出さない
        guard TextDiff.hunks(from: original, to: result).contains(where: { !TextDiff.isWhitespaceOnly($0) }) else { return nil }
        return result
    }
}

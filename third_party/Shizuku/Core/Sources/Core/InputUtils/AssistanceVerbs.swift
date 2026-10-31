import Foundation
import CryptoKit

/// IMKに依存しない、採用・退け・戻すの条件。本文は欄の間のメモリにだけ置く。
public enum AssistanceVerbs {
    /// 最初の 1 文。先頭の改行・空白は次の文と一緒にする（Tab で改行だけが入り、本文が入らないように見えるため）
    public static func firstSentence(_ text: String) -> String {
        let start = text.firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
        guard let end = text[start...].firstIndex(where: { "。！？!?\n".contains($0) }) else { return text }
        var next = text.index(after: end)
        while next < text.endIndex, "」』）)]】〉》".contains(text[next]) { next = text.index(after: next) }
        return String(text[..<next])
    }
    /// 続きの先頭の改行を除く。チャットの 1 行の欄・AI への入力・改行のない短い下書きでは、新しい段落を始めず同じ行に続ける
    /// （1 行の欄では改行が見えず、Tab で何も入らないように見える）。それ以外の文書では段落の区切りを残す
    public static func inlineContinuation(_ text: String, left: String, singleLine: Bool) -> String {
        guard text.first?.isNewline == true else { return text }
        guard singleLine || (!left.contains(where: \.isNewline) && left.count < 200) else { return text }
        return String(text.drop { $0.isWhitespace })
    }
    public static func chunk(_ text: String, all: Bool) -> (text: String, remaining: String) {
        let chosen = all ? text : firstSentence(text)
        return (chosen, String(text.dropFirst(chosen.count)))
    }
    public static func canUndo(chunk: String, left: String?, elapsed: TimeInterval) -> Bool {
        !chunk.isEmpty && elapsed >= 0 && elapsed <= 2 && left?.hasSuffix(chunk) == true
    }
    public static func backspace(_ text: String, caret: Int, selectionLength: Int) -> (text: String, caret: Int)? {
        let value = text as NSString
        guard caret >= 0, selectionLength >= 0, caret + selectionLength <= value.length else { return nil }
        let range: NSRange
        if selectionLength > 0 { range = value.rangeOfComposedCharacterSequences(for: NSRange(location: caret, length: selectionLength)) }
        else {
            guard caret > 0 else { return nil }
            range = value.rangeOfComposedCharacterSequence(at: caret - 1)
        }
        return (value.replacingCharacters(in: range, with: ""), range.location)
    }
    public static func canSummon(helpVisible: Bool, marked: Bool) -> Bool { helpVisible || marked }
    public static func canDismiss(helpVisible: Bool, composing: Bool) -> Bool { helpVisible && !composing }
    public static func choice(number: Int, count: Int, marked: Bool, choicesVisible: Bool) -> Int? {
        guard marked || choicesVisible, (1...3).contains(number), number <= count else { return nil }
        return number - 1
    }
    public static let immediateApps: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.VSCode",
    ]
    public static func shouldStage(_ text: String, app: String?, failedApps: Set<String> = []) -> Bool {
        text.count > 12 && !immediateApps.contains(app ?? "") && !failedApps.contains(app ?? "")
    }
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public struct TabTracker: Sendable {
        private var pending: (scene: String, left: String)?
        public init() {}
        public mutating func passed(scene: String, left: String?) {
            pending = left.map { (PersonalScene.baseKey(of: scene), String($0.suffix(min(20, max(1, $0.count / 2))))) }
        }
        public mutating func observe(scene: String, left: String?) -> Bool {
            defer { pending = nil }
            guard let pending, pending.scene == PersonalScene.baseKey(of: scene), let left else { return false }
            let appended: Substring
            if pending.left.isEmpty { appended = left[...] }
            else if let range = left.range(of: pending.left, options: .backwards) { appended = left[range.upperBound...] }
            else { return false }
            // 改行や欄の送信を、アプリのTab補完と見なさない。
            return !appended.isEmpty && !appended.contains(where: \.isNewline)
        }
        public mutating func reset() { pending = nil }
    }
}

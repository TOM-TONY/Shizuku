import Foundation

/// commitComposition の前に、アプリが入力中の文字を自分で確定していたかの判定。
///
/// Chromium 系の一部のアプリ（Slack など）は、空の欄で最初の文字を入力すると、入力中の文字をそのまま本文として残し、
/// 入力中の範囲を消してから commitComposition を呼ぶ。ここで同じ文字列を挿入すると「s」が「ss」になる。
public enum ClientCompositionCommit {
    /// アプリに入力中の範囲が残っておらず、カーソルより前が表示していた入力中の文字で終わっていれば true
    public static func committedByClient(markedText: String, clientMarkedRange: NSRange, leftContext: String?) -> Bool {
        guard !markedText.isEmpty else { return false }
        guard clientMarkedRange.location == NSNotFound || clientMarkedRange.length == 0 else { return false }
        return leftContext?.hasSuffix(markedText) == true
    }

    /// アプリが確定した入力中の文字を、確定する文字列で置き換える範囲。同じ文字列なら挿入しない（nil）
    public static func replacementRange(committing text: String, markedText: String, caret: Int) -> NSRange? {
        guard text != markedText else { return nil }
        let length = (markedText as NSString).length
        guard !ClientTextRange.isUnknown(caret), caret >= length else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: caret - length, length: length)
    }
}

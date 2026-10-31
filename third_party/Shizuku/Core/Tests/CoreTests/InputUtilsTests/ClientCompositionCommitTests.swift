import Foundation
import Testing
@testable import Core

@Test func clientCommitIsDetectedOnlyWhenTheAppDroppedItsMarkedRangeAndKeptTheText() {
    let none = NSRange(location: NSNotFound, length: 0)
    #expect(ClientCompositionCommit.committedByClient(markedText: "s", clientMarkedRange: none, leftContext: "s"))
    #expect(ClientCompositionCommit.committedByClient(markedText: "あ", clientMarkedRange: NSRange(location: 3, length: 0), leftContext: "本文\nあ"))
    // アプリに入力中の範囲が残っていれば、従来どおり挿入して置き換える
    #expect(!ClientCompositionCommit.committedByClient(markedText: "s", clientMarkedRange: NSRange(location: 0, length: 1), leftContext: "s"))
    // アプリが入力中の文字を捨てた（本文に残っていない）なら挿入する
    #expect(!ClientCompositionCommit.committedByClient(markedText: "s", clientMarkedRange: none, leftContext: ""))
    #expect(!ClientCompositionCommit.committedByClient(markedText: "s", clientMarkedRange: none, leftContext: nil))
    #expect(!ClientCompositionCommit.committedByClient(markedText: "", clientMarkedRange: none, leftContext: "s"))
}

@Test func clientCommitSkipsTheSameTextAndReplacesTheAppCommittedReading() {
    #expect(ClientCompositionCommit.replacementRange(committing: "s", markedText: "s", caret: 1) == nil)
    #expect(ClientCompositionCommit.replacementRange(committing: "ん", markedText: "n", caret: 5) == NSRange(location: 4, length: 1))
    #expect(ClientCompositionCommit.replacementRange(committing: "😀です", markedText: "😀", caret: 2) == NSRange(location: 0, length: 2))
    #expect(ClientCompositionCommit.replacementRange(committing: "ん", markedText: "n", caret: NSNotFound)?.location == NSNotFound)
}

@Test func clientCommitDoesNotReplaceAtAnUnknownCaret() {
    // IMK の境界で 32 ビットに切り詰められた NSNotFound（Electron 製のアプリ）
    let unknown = Int(Int32.max)
    #expect(ClientCompositionCommit.replacementRange(committing: "ん", markedText: "n", caret: unknown)?.location == NSNotFound)
}

@Test func compositionStartsAtTheCaretOnlyOverAnApplicationOwnedMarkedRange() {
    let none = NSRange(location: NSNotFound, length: 0)
    let truncated = NSRange(location: Int(Int32.max), length: 0)
    // 貼り付けが残した入力中の範囲は置き換えず、カーソルから始める
    #expect(ClientTextRange.compositionStart(clientMarked: NSRange(location: 0, length: 11), selected: { NSRange(location: 11, length: 0) })
        == NSRange(location: 11, length: 0))
    // アプリに入力中の範囲がなければ、カーソル位置を問い合わせずアプリの選択に任せる
    var queried = false
    #expect(ClientTextRange.compositionStart(clientMarked: none, selected: { queried = true; return NSRange(location: 3, length: 0) }) == none)
    #expect(ClientTextRange.compositionStart(clientMarked: truncated, selected: { queried = true; return NSRange(location: 3, length: 0) }) == none)
    #expect(ClientTextRange.compositionStart(clientMarked: NSRange(location: 3, length: 0), selected: { queried = true; return NSRange(location: 3, length: 0) }) == none)
    #expect(!queried)
    // カーソル位置が分からなければ、範囲外の位置を渡さない
    #expect(ClientTextRange.compositionStart(clientMarked: NSRange(location: 0, length: 2), selected: { truncated }) == none)
    #expect(ClientTextRange.compositionStart(clientMarked: NSRange(location: 0, length: 2), selected: { none }) == none)
    #expect(ClientTextRange.compositionStart(clientMarked: NSRange(location: Int(Int32.max), length: 2), selected: { NSRange(location: 2, length: 0) }) == none)
}

@Test func compositionUpdatesChangeOnlyTheEndOfTheMarkedText() {
    // 変わらない末尾の前への挿入は、末尾を除いた部分を先に送る
    #expect(ClientCompositionUpdate.intermediateLength(from: "t", to: "っt") == 1)
    #expect(ClientCompositionUpdate.intermediateLength(from: "かt", to: "かっt") == 2)
    #expect(ClientCompositionUpdate.intermediateLength(from: "きょうは", to: "今日は") == 2)
    #expect(ClientCompositionUpdate.intermediateLength(from: "😀t", to: "😀っt") == 3)
    // 末尾での追加・置き換えはそのまま送る
    #expect(ClientCompositionUpdate.intermediateLength(from: "っt", to: "って") == nil)
    #expect(ClientCompositionUpdate.intermediateLength(from: "t", to: "て") == nil)
    #expect(ClientCompositionUpdate.intermediateLength(from: "め", to: "めn") == nil)
    #expect(ClientCompositionUpdate.intermediateLength(from: "めn", to: "め") == nil)
    #expect(ClientCompositionUpdate.intermediateLength(from: "tt", to: "tt") == nil)
    // 入力の開始と、先頭を消すだけの更新は分けない
    #expect(ClientCompositionUpdate.intermediateLength(from: "", to: "t") == nil)
    #expect(ClientCompositionUpdate.intermediateLength(from: "っt", to: "t") == nil)
}

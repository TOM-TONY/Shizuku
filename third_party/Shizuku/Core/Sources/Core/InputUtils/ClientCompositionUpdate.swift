import Foundation

/// 入力中の文字の更新を、変わる部分がいつも末尾に来る形で送るための判定。
///
/// Chromium は入力中の文字を、前の文字列との共通の先頭と末尾を除いた部分だけ書き換える。「t」→「っt」のように、
/// 変わらない末尾の前へ挿入する更新では、ProseMirror の入力欄（Codex など）がリンクなどの印の境目で DOM と自分の状態を
/// 食い違わせ、入力中の文字が重なったり、直前に貼り付けた文が消えたりする。末尾での置き換え・追加なら起きない。
public enum ClientCompositionUpdate {
    /// 前の入力中の文字 old から new へ更新する前に、先に送る途中の文字列の長さ（UTF-16）。
    /// new の、old と共通の末尾を除いた部分を先に送れば、どちらの更新も末尾での置き換え・追加になる。分ける必要がなければ nil
    public static func intermediateLength(from old: String, to new: String) -> Int? {
        guard !old.isEmpty, old != new else { return nil }
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        // 先頭を消すだけの更新（途中の文字列が空になる）は、空の入力中の文字で取り消さないよう分けない
        guard suffix > 0, after.count > suffix else { return nil }
        return String(after[..<(after.count - suffix)]).utf16.count
    }
}

import Foundation

/// アプリ（IMK の client）が返す位置・範囲の扱い。
///
/// 位置を答えないアプリは NSNotFound か、IMK の境界で 32 ビットに切り詰められた NSNotFound（2147483647）を返す（Electron 製の Codex など）。
/// これを実在の位置として置き換え範囲に使うと、Chromium は範囲外の選択を作れずに入力中の文字を取り消し、入力欄のカーソルも外れる。
public enum ClientTextRange {
    /// アプリが位置・長さを答えなかった値か
    public static func isUnknown(_ value: Int) -> Bool {
        value == NSNotFound || value < 0 || value >= Int(Int32.max)
    }

    /// 入力を始めるときに setMarkedText へ渡す置き換え範囲。
    /// アプリが自分の入力中の範囲を持っている（貼り付けが残したなど）ときだけ、それを置き換えないようカーソル位置を明示する。
    /// それ以外と、カーソル位置が分からないときは NSNotFound にして、アプリの今の選択に任せる
    public static func compositionStart(clientMarked: NSRange, selected: () -> NSRange) -> NSRange {
        let implicit = NSRange(location: NSNotFound, length: 0)
        guard clientMarked.length > 0, !self.isUnknown(clientMarked.location), !self.isUnknown(clientMarked.length) else { return implicit }
        let selection = selected()
        guard !self.isUnknown(selection.location), !self.isUnknown(selection.length) else { return implicit }
        return selection
    }
}

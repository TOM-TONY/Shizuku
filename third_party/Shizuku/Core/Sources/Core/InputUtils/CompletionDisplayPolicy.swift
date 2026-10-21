import Foundation

/// 文字単位の境界近似。新しい予測が末尾の助詞・句読点まで届いた場合を文節の区切りとする。
public enum CompletionDisplayPolicy {
    public static let boundaries = Set("はがをにでともへの、，。！？!?\n")
    public static func shouldReplace(_ previous: String, with next: String) -> Bool {
        guard previous != next else { return false }
        if !next.hasPrefix(previous) { return true }
        if next.count - previous.count >= 12 { return true }
        return next.last.map { boundaries.contains($0) } ?? false
    }
}

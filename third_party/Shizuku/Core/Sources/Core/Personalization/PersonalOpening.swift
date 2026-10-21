import Foundation

// MARK: - 文の骨組みの先出し（書き出し）（llm-ime、フェーズ 4）
//
// 空の入力欄に書き始めた最初の文（書き出し。「お疲れさまです。」など）を場面ごとに数え、同じ場面の空の欄で、手を止めたら
// いつもの書き出しを灰色で出す（Tab で入れる）。場面の段だけ。5 回以上記録があり、最も多い書き出しが 4 割以上のときだけ出し、
// 自動表示の可否はServer共通のWilson下限の門で決める。

public enum PersonalOpening {
    public static let minimumOpenings = 5
    public static let minimumShare = 0.4
    public static let minimumLength = 2
    public static let maximumLength = 40

    /// 空の欄に書き始めた文字列から、書き出し（最初の文。文末の記号まで）を取り出す。まだ文が終わっていなければ nil
    /// （final なら、文末がなくてもそこまでを書き出しとする）。短すぎる・長すぎる・秘密らしいものは nil
    public static func extract(_ text: String, final: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let sentence: String
        if let end = trimmed.firstIndex(where: { "。！？!?\n".contains($0) }) {
            sentence = String(trimmed[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if final || trimmed.count > Self.maximumLength {
            sentence = trimmed
        } else {
            return nil
        }
        guard sentence.count >= Self.minimumLength, sentence.count <= Self.maximumLength, !PersonalPrivacy.looksSecret(sentence) else {
            return nil
        }
        return sentence
    }

    /// 集めている書き出しに確定した文字列を足す。最初の文が終わった（。！？!? 改行）か上限（40 字）を超えたら集めるのをやめ
    /// （capture が nil）、書き出しを返す（最初の文だけ。上限を超えて文が終わらなければ記録しない＝nil）。
    /// 欄の長さをいつも 0 と返すアプリで集め終わりの合図がなくても、書き出しがメッセージ全体に伸びないようにする
    public static func append(_ capture: String, _ committed: String) -> (capture: String?, opening: String?) {
        let text = capture + committed
        if Self.isIncomplete(text) {
            return (text, nil)
        }
        return (nil, Self.extract(text, final: false))
    }

    /// まだ書き出しを集めている途中か（文が終わっておらず、長さも上限に届いていない）
    public static func isIncomplete(_ text: String) -> Bool {
        !text.contains(where: { "。！？!?\n".contains($0) }) && text.count <= Self.maximumLength
    }

    /// 空の欄で書き出しを置く位置（カーソルの矩形）が使えるか。Chromium 系は空の欄で初期化されていない値や 0 の矩形を返すことがあるので、
    /// 有限で大きさがもっともらしく、原点でなく、どれかの画面の中にあり、入力先のアプリ（pid で選んだ）のウィンドウの中にあるときだけ使う。
    /// 使えなければ出さない（画面の原点や前の位置には出さない）
    public static func isUsableAnchor(_ rect: CGRect, screens: [CGRect], clientWindow: CGRect?) -> Bool {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              (4...200).contains(rect.height), rect.width >= 0, rect.origin != .zero,
              let clientWindow else {
            return false
        }
        let onScreen = screens.contains { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: rect.minX, y: rect.midY)) }
        return onScreen && clientWindow.insetBy(dx: -40, dy: -4).contains(CGPoint(x: rect.minX, y: rect.midY))
    }

    /// その場面で出す書き出し（出さなければ nil）
    public static func suggestion(tallies: [String: Int]?, ignores: Int) -> String? {
        guard let tallies else {
            return nil
        }
        let total = tallies.values.reduce(0, +)
        guard total >= Self.minimumOpenings,
              let top = tallies.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              Double(top.value) / Double(total) >= Self.minimumShare else {
            return nil
        }
        return top.key
    }
}

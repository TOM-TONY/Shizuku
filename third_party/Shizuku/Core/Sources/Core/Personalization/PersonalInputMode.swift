import Foundation

// MARK: - 場面に合わせた入力モード（llm-ime、フェーズ 3）
//
// 入力欄に入ってから最初に文字を打ったときの入力モード（英数かかなか。その前に自分で切り替えたか）をアプリごとに数え、
// 最近の観測ほど重い得票で「そのアプリではいつもこのモードで書く」を決める（3 回以上そろい、そのうち 1 回以上は自分で
// 切り替えていて、2 番目の 3 倍以上のとき）。設定「入力欄に合わせて英数・かなを切り替える」（既定はオフ）がオンのときだけ、
// 入力欄に入った時点でそのモードにする。オフのときも観測は数えるが、決して切り替えない。

public enum PersonalInputMode {
    public struct Votes: Codable, Equatable, Sendable {
        /// 言語 → 得票（最近の観測ほど重い）
        public var scores: [String: Double] = [:]
        public var counts: [String: Int] = [:]
        /// 自分で切り替えて打った回数（言語ごと）
        public var switched: [String: Int] = [:]
        public var last: Double = 0

        public init() {}
    }

    public static func key(_ language: InputLanguage) -> String {
        language == .english ? "english" : "japanese"
    }

    public static func language(_ key: String) -> InputLanguage? {
        switch key {
        case "english": .english
        case "japanese": .japanese
        default: nil
        }
    }

    public static let decay = 0.7
    public static let minimumCount = 3
    public static let margin = 3.0

    /// 観測を 1 つ足す（language は最初に文字を打ったときのモード、switched はその前に自分で切り替えたか）
    public static func add(_ votes: inout Votes, language: InputLanguage, switched: Bool, now: Double) {
        let key = Self.key(language)
        for other in votes.scores.keys where other != key {
            votes.scores[other]! *= Self.decay
        }
        votes.scores[key] = (votes.scores[key] ?? 0) * Self.decay + 1
        votes.counts[key, default: 0] += 1
        if switched {
            votes.switched[key, default: 0] += 1
        }
        votes.last = now
    }

    /// そのアプリでいつも使うモード（決まらなければ nil）
    public static func preferred(_ votes: Votes) -> InputLanguage? {
        let ranked = votes.scores.sorted { $0.value > $1.value }
        guard let top = ranked.first, let language = Self.language(top.key),
              votes.counts[top.key, default: 0] >= Self.minimumCount, votes.switched[top.key, default: 0] >= 1 else {
            return nil
        }
        let second = ranked.dropFirst().first?.value ?? 0
        return top.value >= Self.margin * second ? language : nil
    }

    /// 入力欄に入ったときに切り替えるか。設定がオフなら決して切り替えない。まだ何も打っておらず、今のモードと違うときだけ
    public static func switchTarget(
        enabled: Bool, preferred: InputLanguage?, current: InputLanguage, typedSinceActivation: Bool
    ) -> InputLanguage? {
        guard enabled, !typedSinceActivation, let preferred, preferred != current else {
            return nil
        }
        return preferred
    }
}

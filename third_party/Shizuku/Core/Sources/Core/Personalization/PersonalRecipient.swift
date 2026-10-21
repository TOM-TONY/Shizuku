import Foundation

/// 相手の段の規則。先頭60字をその場で見るだけで、宛名・名前・本文は保持しない。
public enum PersonalRecipient {
    public enum Rank: String, Codable, Sendable, CaseIterable { case r1, r2, r3 }
    // 強い丁寧さを先に見る。宛名の接尾辞は語中（様子・たくさん等）に当てない。
    static let rules: [(Rank, NSRegularExpression)] = [
        (.r3, try! NSRegularExpression(pattern: "(?<![同仕模多一異各])様(?=$|[\\s、。！？!?])|御中|拝啓|お世話になっております|恐れ入りますが|いたします|いたしました|いたしております|致します|致しました")),
        (.r2, try! NSRegularExpression(pattern: "(?<!たく)さん(?=$|[\\s、。！？!?])|お疲れ様です|お疲れさまです|(?:です|ます)(?=$|[。！？!?\\n])")),
        (.r1, try! NSRegularExpression(pattern: "(?:ちゃん|くん)(?=$|[\\s、。！？!?])|(?:だ|である|じゃん|だよ|かな)(?=$|[。！？!?\\n])"))
    ]
    public static func infer(prefix: String) -> Rank? {
        let text = String(prefix.prefix(60))
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (rank, rule) in rules where rule.firstMatch(in: text, range: range) != nil { return rank }
        if text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return .r1 }
        if text.unicodeScalars.contains(where: { $0.value == 0xfe0f }) && text.unicodeScalars.contains(where: { $0.properties.isEmoji }) { return .r1 }
        return nil
    }

    /// 欄にいる間の符号とフラグだけ。未定も一度決めたら見直さない。
    public struct State: Sendable {
        public private(set) var rank: Rank?
        public private(set) var decided = false
        private var newField: Bool?
        public init() {}
        public mutating func reset() { self = State() }
        public mutating func observe(mode: PersonalScene.Mode, left: String?, enabled: Bool, startedEmpty: Bool = false) {
            guard enabled else { reset(); return }
            if newField == nil { newField = mode == .new && startedEmpty }
            guard newField == true, !decided, let left else { return }
            let prefix = String(left.prefix(60))
            var sentences = 0, hasBody = false
            for c in prefix {
                if "。！？!?\n".contains(c) {
                    if hasBody { sentences += 1; hasBody = false }
                } else if !c.isWhitespace { hasBody = true }
            }
            guard prefix.count >= 60 || sentences >= 2 else { return }
            rank = infer(prefix: prefix)
            decided = true
        }
    }
}

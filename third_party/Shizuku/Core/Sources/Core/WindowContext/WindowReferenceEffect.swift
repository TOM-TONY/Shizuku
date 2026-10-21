import Foundation

/// llm-ime: 画面の参考資料を使った提案と使わなかった提案の、表示と採用の数（本文なし・60 日）。
/// 反応の種類は "wref_<1|0>_<種類>_<shown|accepted>"。採否はここでは決めない（記録がたまってから LabGate で判定する）
public struct WindowReferenceEffect: Sendable {
    public static let window: Double = 60 * 86400
    public static let prefix = "wref_"
    public struct Key: Hashable, Sendable, Comparable {
        public var kind: String
        public var used: Bool
        public static func < (a: Key, b: Key) -> Bool { (a.kind, a.used ? 1 : 0) < (b.kind, b.used ? 1 : 0) }
    }
    private var events: [Key: [(ts: Double, accepted: Bool)]] = [:]
    public init() {}

    public static func reaction(kind: String, used: Bool, accepted: Bool) -> String {
        prefix + (used ? "1" : "0") + "_" + kind + (accepted ? "_accepted" : "_shown")
    }

    public mutating func observe(reaction: String, ts: Double) {
        guard reaction.hasPrefix(Self.prefix), ts.isFinite else { return }
        let body = reaction.dropFirst(Self.prefix.count)
        guard let flag = body.first, flag == "0" || flag == "1", body.dropFirst().first == "_" else { return }
        let rest = String(body.dropFirst(2))
        let accepted = rest.hasSuffix("_accepted"), shown = rest.hasSuffix("_shown")
        guard accepted || shown else { return }
        let kind = String(rest.dropLast(accepted ? 9 : 6))
        guard !kind.isEmpty else { return }
        events[Key(kind: kind, used: flag == "1"), default: []].append((ts, accepted))
    }

    public func counts(now: Double) -> [Key: (shown: Int, accepted: Int)] {
        let since = now - Self.window
        return events.mapValues { list in
            let recent = list.filter { $0.ts >= since }
            return (recent.filter { !$0.accepted }.count, recent.filter(\.accepted).count)
        }
    }

    public func summary(now: Double) -> String {
        let counts = counts(now: now)
        guard !counts.isEmpty else { return "画面の参考資料の効果: まだ記録がありません" }
        let rows = counts.keys.sorted().map { key -> String in
            let value = counts[key]!
            let rate = value.shown == 0 ? "—" : String(format: "%.1f%%", 100 * Double(value.accepted) / Double(value.shown))
            return "\(key.kind) \(key.used ? "参考あり" : "参考なし"): 採用\(value.accepted)/表示\(value.shown)（\(rate)）"
        }
        return (["画面の参考資料の効果（60日、本文なし）"] + rows).joined(separator: "\n")
    }
}

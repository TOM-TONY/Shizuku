import Foundation

/// 本文を持たない60日分の反応。キーの流れではSQLiteを読まない。
public struct PersonalOfferTrust: Sendable {
    public static let window: Double = 60 * 86400
    public static let minimumShown = 20
    public static let threshold = 0.05
    public struct Key: Hashable, Sendable {
        public let scene: String
        public let kind: OfferKind
        public init(scene: String, kind: OfferKind) { self.scene = PersonalScene.baseKey(of: scene); self.kind = kind }
    }
    public struct Status: Sendable {
        public var shown: Int, accepted: Int
        public var lowerBound: Double { PersonalOfferTrust.wilson(shown: shown, accepted: accepted) }
        public var muted: Bool { shown >= PersonalOfferTrust.minimumShown && lowerBound < PersonalOfferTrust.threshold }
    }
    private struct Evidence: Sendable { var ts: Double; var shown: Bool }
    private struct Bucket: Sendable {
        var events: [Evidence] = []
        var head = 0, shown = 0, accepted = 0
        mutating func prune(_ cutoff: Double) {
            while head < events.count, events[head].ts < cutoff {
                if events[head].shown { shown -= 1 } else { accepted -= 1 }
                head += 1
            }
            if head > 1024, head * 2 > events.count { events.removeFirst(head); head = 0 }
        }
    }
    private var buckets: [Key: Bucket] = [:]
    private var probes: [Key: Int] = [:]
    public init() {}
    public var hasEvidence: Bool { !buckets.isEmpty }
    public static func wilson(shown: Int, accepted: Int) -> Double {
        guard shown > 0 else { return 0 }
        let n = Double(shown), p = Double(min(shown, max(0, accepted))) / n, z = 1.959963984540054
        return max(0, (p + z*z/(2*n) - z*sqrt(p*(1-p)/n + z*z/(4*n*n))) / (1 + z*z/n))
    }
    public mutating func observe(reaction: String, scene: String?, ts: Double) {
        guard let scene, ts.isFinite else { return }
        let shown = reaction.hasSuffix("_shown"), accepted = reaction.hasSuffix("_accepted")
        guard shown || accepted, let kind = OfferKind(rawValue: String(reaction.dropLast(shown ? 6 : 9))), kind != .prediction, kind != .quote else { return }
        let key = Key(scene: scene, kind: kind)
        var bucket = buckets[key] ?? Bucket()
        // shownがなかった旧記録の採用だけで、新しいshownの率を水増ししない。
        guard shown || bucket.shown > 0 else { return }
        if let last = bucket.events.last, ts < last.ts {
            bucket.events.removeFirst(bucket.head); bucket.head = 0
            bucket.events.append(.init(ts: ts, shown: shown)); bucket.events.sort { $0.ts < $1.ts }
        } else { bucket.events.append(.init(ts: ts, shown: shown)) }
        if shown { bucket.shown += 1 } else { bucket.accepted += 1 }
        buckets[key] = bucket
    }
    public mutating func status(_ key: Key, now: Double) -> Status {
        buckets[key]?.prune(now - Self.window)
        return .init(shown: buckets[key]?.shown ?? 0, accepted: buckets[key]?.accepted ?? 0)
    }
    public mutating func allow(_ key: Key, now: Double) -> Bool {
        guard status(key, now: now).muted else { probes[key] = 0; return true }
        let count = (probes[key] ?? 0) + 1
        probes[key] = count % 10
        return count % 10 == 0
    }
    public mutating func muted(now: Double) -> [(Key, Status)] {
        buckets.keys.sorted { ($0.scene, $0.kind.rawValue) < ($1.scene, $1.kind.rawValue) }.compactMap {
            let value = status($0, now: now)
            return value.muted ? ($0, value) : nil
        }
    }
    public mutating func forget(app: String) {
        buckets = buckets.filter { PersonalScene(key: $0.key.scene)?.app != app }
        probes = probes.filter { PersonalScene(key: $0.key.scene)?.app != app }
    }
}

import Foundation

/// 出所の仕分け。本文を扱う照合はstore.queueだけで行い、表示には数だけを返す。
public enum PersonalOrigin {
    public static let generatedKinds: Set<String> = ["completion", "idle", "skeleton", "ai", "rewrite"]
    public static let normalKinds: Set<String> = ["selection", "enter", "transform", "kana"]
    public static func initial(kind: String) -> Int { generatedKinds.contains(kind) ? 1 : 0 }
    public static func isMaterial(_ origin: Int) -> Bool { origin == 0 || origin == 2 }

    public static func edited(kind: String, length: Int, ts: Double, reaction: String, n: Int?, now: Double) -> Bool {
        guard let n, n >= 0, now >= ts else { return false }
        if reaction == "bs_after_commit" { return n > 0 && now - ts <= 120 }
        return reaction == "completion_kept" && ["completion", "idle"].contains(kind) && n < length
    }
    public struct Entry: Sendable {
        public var id: Int64
        public var ts: Double
        public var scene: String
        public var kind: String
        public var text: String
        public var origin: Int
    }
    public static func grams(_ text: String) -> Set<String> {
        let chars = Array(text.precomposedStringWithCompatibilityMapping)
        guard chars.count >= 2 else { return [] }
        return Set((1..<chars.count).map { String(chars[($0 - 1)...$0]) })
    }
    /// 支持する通常確定は2つの異なる日が必要。同日の繰り返しや昇格文による再帰的な昇格は数えない。
    public static func canPromote(_ text: String, authored: [(ts: Double, text: String)]) -> Bool {
        Evidence(authored).supports(text)
    }
    private struct Evidence {
        var postings: [String: [Int]] = [:]
        var days: [Int] = []
        init(_ rows: [(ts: Double, text: String)]) {
            for (index, row) in rows.enumerated() {
                days.append(LabReplay.day(row.ts))
                for gram in grams(row.text) { postings[gram, default: []].append(index) }
            }
        }
        func supports(_ text: String) -> Bool {
            let target = grams(text)
            guard !target.isEmpty else { return false }
            var covered: [Int: Int] = [:]
            for gram in target {
                for index in postings[gram] ?? [] { covered[index, default: 0] += 1 }
            }
            return Set(covered.compactMap { $0.value * 5 >= target.count * 4 ? days[$0.key] : nil }).count >= 2
        }
    }
    public static func acceptEdit(store: PersonalStore, id: Int64, reaction: String, n: Int?, now: Double) throws -> Bool {
        var accepts = false
        try store.query("SELECT ts,kind,surface FROM commits WHERE id=? AND origin=1", [.int(id)]) { row in
            accepts = edited(kind: row.text(1) ?? "", length: (row.text(2) ?? "").count, ts: row.double(0), reaction: reaction, n: n, now: now)
        }
        if accepts { try store.execute("UPDATE commits SET origin=0 WHERE id=? AND origin=1", [.int(id)]) }
        return accepts
    }
    public static func promote(store: PersonalStore) throws -> Bool {
        var candidates: [(Int64, String)] = []
        try store.query("SELECT id,surface FROM commits WHERE origin=1 ORDER BY ts DESC,id DESC LIMIT 200") {
            candidates.append(($0.int(0), $0.text(1) ?? ""))
        }
        guard !candidates.isEmpty else { return false }
        var authored: [(ts: Double, text: String)] = []
        try store.query("SELECT ts,surface FROM commits WHERE origin=0 AND kind IN ('selection','enter','transform','kana') ORDER BY ts,id") {
            authored.append(($0.double(0), $0.text(1) ?? ""))
        }
        var changed = false
        let evidence = Evidence(authored)
        for (id, text) in candidates where evidence.supports(text) {
            try store.execute("UPDATE commits SET origin=2 WHERE id=? AND origin=1", [.int(id)])
            changed = true
        }
        return changed
    }
    public static func entries(store: PersonalStore, materialOnly: Bool = true) throws -> [Entry] {
        var rows: [Entry] = []
        let condition = materialOnly ? "WHERE origin IN (0,2)" : ""
        try store.query("SELECT id,ts,scene,kind,surface,origin FROM commits \(condition) ORDER BY ts DESC,id DESC LIMIT 60000") {
            rows.append(Entry(id: $0.int(0), ts: $0.double(1), scene: $0.text(2) ?? "", kind: $0.text(3) ?? "", text: $0.text(4) ?? "", origin: Int($0.int(5))))
        }
        return rows.reversed()
    }
    public static func origins(store: PersonalStore) throws -> [Int64: Int] {
        var origins: [Int64: Int] = [:]
        try store.query("SELECT id,origin FROM commits") { origins[$0.int(0)] = Int($0.int(1)) }
        return origins
    }
    public static func openingIsMaterial(_ sources: [Int64], origins: [Int64: Int]) -> Bool {
        sources.allSatisfy { origins[$0].map(isMaterial) ?? false }
    }
    public static func openings(store: PersonalStore, origins: [Int64: Int]) throws -> [(scene: String, text: String)] {
        var rows: [(scene: String, text: String)] = []
        try store.query("SELECT scene,text,sources FROM openings ORDER BY ts,id") { row in
            guard let data = row.text(2)?.data(using: .utf8), let sources = try? JSONDecoder().decode([Int64].self, from: data),
                  openingIsMaterial(sources, origins: origins) else { return }
            rows.append((row.text(0) ?? "", row.text(1) ?? ""))
        }
        return rows
    }
}

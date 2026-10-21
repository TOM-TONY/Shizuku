import Crypto
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// 消した部分の照合キーだけを保存する。元の文を復元できないことの保証ではない。
public enum PersonalRewritePrivacy {
    static let saltKey = "rewrite.salt.v1"
    static let migrationKey = "rewrite.hashed.v1"
    static let migratedRowsKey = "rewrite.migrated.rows"
    static let scrubbedLeftKey = "rewrite.migrated.left"

    static func newSalt() -> String { UUID().uuidString + UUID().uuidString }

    public static func normalized(_ text: String) -> String {
        text.toKatakana().filter { !$0.isWhitespace }
    }

    public static func key(_ text: String, salt: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(Self.normalized(text).utf8), using: SymmetricKey(data: Data(salt.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// 記録する直前の左文脈だけ。最長の一致を優先し、文字数を保って置き換える。
    static func scrub(_ left: String, hashes: Set<String>, salt: String) -> String {
        let characters = Array(left.suffix(20))
        guard !hashes.isEmpty else { return String(characters) }
        var masked = Array(repeating: false, count: characters.count)
        for start in characters.indices {
            for end in (start + 1)...characters.count {
                if hashes.contains(Self.key(String(characters[start..<end]), salt: salt)) {
                    for index in start..<end { masked[index] = true }
                }
            }
        }
        return String(characters.enumerated().map { masked[$0.offset] ? "∗" : $0.element })
    }

    static func meta(_ key: String, store: PersonalStore) throws -> String? {
        var value: String?
        try store.query("SELECT value FROM meta WHERE key=?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    /// 旧行の平文が必要な間に、結べる left を置き換える。再起動しても再ハッシュしない。
    static func migrate(store: PersonalStore) throws -> String {
        let salt = try Self.meta(Self.saltKey, store: store) ?? Self.newSalt()
        try store.transaction {
            try store.execute("INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)", [.text(Self.saltKey), .text(salt)])
            guard try Self.meta(Self.migrationKey, store: store) == nil else { return }
            var rows: [(Int64, Int64?, String)] = []
            try store.query("SELECT id,commit_id,deleted FROM rewrites ORDER BY id") { row in
                rows.append((row.int(0), row.isNull(1) ? nil : row.int(1), row.text(2) ?? ""))
            }
            var scrubbed: Set<Int64> = []
            for (id, commitID, deleted) in rows {
                let hash = Self.key(deleted, salt: salt)
                if let commitID, try Self.scrubCommit(store: store, id: commitID, hashes: [hash], salt: salt) { scrubbed.insert(commitID) }
                try store.execute("UPDATE rewrites SET deleted=? WHERE id=?", [.text(hash), .int(id)])
            }
            var reactions: [(Int64, String)] = []
            try store.query("SELECT id,a FROM reactions WHERE kind IN ('rewrite_accepted','rewrite_ignored') AND a IS NOT NULL") {
                reactions.append(($0.int(0), $0.text(1) ?? ""))
            }
            for (id, text) in reactions {
                try store.execute("UPDATE reactions SET a=? WHERE id=?", [.text(Self.key(text, salt: salt)), .int(id)])
            }
            for (key, value) in [(Self.migrationKey, "1"), (Self.migratedRowsKey, String(rows.count)), (Self.scrubbedLeftKey, String(scrubbed.count))] {
                try store.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [.text(key), .text(value)])
            }
        }
        return salt
    }

    @discardableResult
    static func scrubCommit(store: PersonalStore, id: Int64, hashes: Set<String>, salt: String) throws -> Bool {
        var left: String?
        try store.query("SELECT left FROM commits WHERE id=?", [.int(id)]) { left = $0.text(0) }
        guard let left else { return false }
        let scrubbed = Self.scrub(left, hashes: hashes, salt: salt)
        guard left != scrubbed else { return false }
        try store.execute("UPDATE commits SET left=? WHERE id=?", [.text(scrubbed), .int(id)])
        return true
    }

    static func scrubRecordedLeft(_ left: String, store: PersonalStore) throws -> String {
        var hashes: Set<String> = []
        try store.query("SELECT DISTINCT deleted FROM rewrites") { if let hash = $0.text(0) { hashes.insert(hash) } }
        return Self.scrub(left, hashes: hashes, salt: store.rewriteSalt)
    }
}

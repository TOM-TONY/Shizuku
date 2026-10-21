import Foundation
import SQLite3

/// llm-ime: 場面学習の記録（パーソナルコーパス）を入れる SQLite。
///
/// 変換サーバー（サンドボックスの外）だけが開く。読み書きはすべて `queue` の上で行い、キー入力の処理（主スレッド）を待たせない。
/// 置き場所は既存の学習データと同じコンテナ（`Application Support/Shizuku/personal/personal.sqlite`）
public final class PersonalStore: @unchecked Sendable {
    public enum Value: Sendable {
        case int(Int64)
        case double(Double)
        case text(String)
        case null

        public static func optionalText(_ text: String?) -> Value {
            text.map { .text($0) } ?? .null
        }

        public static func optionalInt(_ value: Int?) -> Value {
            value.map { .int(Int64($0)) } ?? .null
        }
    }

    public struct Row {
        fileprivate let statement: OpaquePointer

        public func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(self.statement, column)
        }

        public func double(_ column: Int32) -> Double {
            sqlite3_column_double(self.statement, column)
        }

        public func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(self.statement, column) else {
                return nil
            }
            return String(cString: pointer)
        }

        public func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(self.statement, column) == SQLITE_NULL
        }
    }

    public struct StoreError: Error, CustomStringConvertible {
        public var description: String
    }

    public static let schemaVersion = 1

    public let url: URL
    /// 読み書きはこのキューの上だけで行う
    public let queue = DispatchQueue(label: "dev.tomonari.inputmethod.Shizuku.personalStore", qos: .utility)
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 開いて表を用意する（呼び出し側のスレッドで行う。起動時に裏で呼ぶ）
    public private(set) var rewriteSalt = ""

    func resetRewriteSalt(_ salt: String) throws {
        try self.execute("DELETE FROM meta WHERE key LIKE 'rewrite.%'")
        try self.execute("INSERT INTO meta(key,value) VALUES(?,?)", [.text(PersonalRewritePrivacy.saltKey), .text(salt)])
        try self.execute("INSERT INTO meta(key,value) VALUES(?,'1')", [.text(PersonalRewritePrivacy.migrationKey)])
        self.rewriteSalt = salt
    }

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StoreError(description: message)
        }
        self.db = handle
        try self.executeScript("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS commits(
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                composition INTEGER,
                scene TEXT NOT NULL,
                app TEXT NOT NULL,
                shape TEXT,
                mode TEXT,
                reply INTEGER,
                from_app TEXT,
                mono INTEGER,
                kind TEXT NOT NULL,
                reading TEXT,
                surface TEXT NOT NULL,
                first TEXT,
                rank INTEGER,
                depth INTEGER,
                left TEXT,
                compose_ms INTEGER,
                keys INTEGER,
                backspaces INTEGER
            );
            CREATE INDEX IF NOT EXISTS commits_ts ON commits(ts);
            CREATE INDEX IF NOT EXISTS commits_scene ON commits(scene);
            CREATE TABLE IF NOT EXISTS reactions(
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                scene TEXT,
                app TEXT,
                commit_id INTEGER,
                kind TEXT NOT NULL,
                a TEXT,
                b TEXT,
                n INTEGER
            );
            CREATE INDEX IF NOT EXISTS reactions_ts ON reactions(ts);
            CREATE TABLE IF NOT EXISTS typo_pairs(
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                scene TEXT,
                app TEXT,
                typed TEXT NOT NULL,
                fixed TEXT NOT NULL,
                reading TEXT
            );
            CREATE TABLE IF NOT EXISTS lexicon(
                scene TEXT NOT NULL,
                app TEXT NOT NULL,
                reading TEXT NOT NULL,
                surface TEXT NOT NULL,
                lcid INTEGER,
                rcid INTEGER,
                mid INTEGER,
                count INTEGER NOT NULL DEFAULT 0,
                nondefault INTEGER NOT NULL DEFAULT 0,
                last REAL NOT NULL,
                score REAL NOT NULL DEFAULT 0,
                PRIMARY KEY(scene, reading, surface)
            );
            CREATE TABLE IF NOT EXISTS pauses(
                level TEXT PRIMARY KEY,
                json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS stalls(
                id TEXT PRIMARY KEY, ts REAL NOT NULL, scene TEXT NOT NULL, app TEXT NOT NULL,
                event TEXT NOT NULL, position INTEGER NOT NULL, seconds REAL, depth INTEGER, deleted_chars INTEGER,
                commit_id INTEGER, weak_label INTEGER NOT NULL DEFAULT 0,
                hid_mouse INTEGER, hid_scroll INTEGER, hid_click INTEGER
            );
            CREATE INDEX IF NOT EXISTS stalls_app_ts ON stalls(app,ts);
            CREATE TABLE IF NOT EXISTS stall_intervals(level TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS stall_bursts(scene TEXT PRIMARY KEY, app TEXT NOT NULL, ts REAL NOT NULL, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS rewrites(
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                scene TEXT,
                app TEXT,
                commit_id INTEGER,
                deleted TEXT NOT NULL,
                written TEXT NOT NULL,
                written_reading TEXT
            );
            CREATE TABLE IF NOT EXISTS openings(
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                scene TEXT NOT NULL,
                app TEXT NOT NULL,
                text TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS closings(
                id INTEGER PRIMARY KEY, ts REAL NOT NULL, scene TEXT NOT NULL, app TEXT NOT NULL,
                text TEXT NOT NULL, sources TEXT NOT NULL DEFAULT '[]'
            );
            CREATE TABLE IF NOT EXISTS taught(
                id TEXT PRIMARY KEY, batch TEXT NOT NULL, ts REAL NOT NULL, scene TEXT NOT NULL,
                app TEXT NOT NULL, text TEXT NOT NULL, origin INTEGER NOT NULL DEFAULT 3 CHECK(origin=3)
            );
            CREATE INDEX IF NOT EXISTS taught_scene ON taught(scene);
            CREATE TABLE IF NOT EXISTS input_mode(
                app TEXT PRIMARY KEY,
                json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tuning(
                level TEXT NOT NULL,
                knob TEXT NOT NULL,
                json TEXT NOT NULL,
                PRIMARY KEY(level, knob)
            );
            CREATE TABLE IF NOT EXISTS context_lexicon(
                context TEXT NOT NULL,
                reading TEXT NOT NULL,
                surface TEXT NOT NULL,
                scene TEXT,
                lcid INTEGER,
                rcid INTEGER,
                mid INTEGER,
                count INTEGER NOT NULL DEFAULT 0,
                nondefault INTEGER NOT NULL DEFAULT 0,
                last REAL NOT NULL,
                score REAL NOT NULL DEFAULT 0,
                PRIMARY KEY(context, reading, surface)
            );
            """)
        try self.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema', ?)", [.text(String(Self.schemaVersion))])
        // 表を作った後に足した列（フェーズ 1 の記録から引き継ぐ）
        for table in ["lexicon", "context_lexicon"] {
            var hasScore = false
            try self.query("PRAGMA table_info(\(table))") { row in
                if row.text(1) == "score" {
                    hasScore = true
                }
            }
            if !hasScore {
                try self.executeScript("ALTER TABLE \(table) ADD COLUMN score REAL NOT NULL DEFAULT 0; UPDATE \(table) SET score = count;")
            }
        }
        // フェーズ 4 の記録だけの版で作った rewrites には、書いた語句の読みの列がない
        var hasWrittenReading = false
        try self.query("PRAGMA table_info(rewrites)") { row in
            if row.text(1) == "written_reading" {
                hasWrittenReading = true
            }
        }
        if !hasWrittenReading {
            try self.executeScript("ALTER TABLE rewrites ADD COLUMN written_reading TEXT;")
        }
        // 既存行は本人由来。書き出しには材料となった確定のIDだけを関連付ける。
        for (table, column, declaration) in [("commits", "origin", "INTEGER NOT NULL DEFAULT 0"),
                                             ("openings", "sources", "TEXT NOT NULL DEFAULT '[]'")] {
            var exists = false
            try self.query("PRAGMA table_info(\(table))") { if $0.text(1) == column { exists = true } }
            if !exists { try self.executeScript("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration);") }
        }
        let legacyRewriteRows = try PersonalRewritePrivacy.meta(PersonalRewritePrivacy.migrationKey, store: self) == nil
            && (try self.scalarInt("SELECT (SELECT COUNT(*) FROM rewrites) + (SELECT COUNT(*) FROM reactions WHERE kind IN ('rewrite_accepted','rewrite_ignored'))") ?? 0) > 0
        self.rewriteSalt = try PersonalRewritePrivacy.migrate(store: self)
        if legacyRewriteRows { try self.eraseFreedPages() }
    }

    deinit {
        for statement in self.statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close(self.db)
    }

    private var errorMessage: String {
        self.db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    public func executeScript(_ sql: String) throws {
        guard sqlite3_exec(self.db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError(description: self.errorMessage)
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = self.statements[sql] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError(description: self.errorMessage + " (\(sql))")
        }
        self.statements[sql] = statement
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [Value]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let value):
                sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
    }

    public func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try self.prepared(sql)
        self.bind(statement, values)
        let result = sqlite3_step(statement)
        sqlite3_reset(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw StoreError(description: self.errorMessage + " (\(sql))")
        }
    }

    public func query(_ sql: String, _ values: [Value] = [], row: (Row) -> Void) throws {
        let statement = try self.prepared(sql)
        self.bind(statement, values)
        defer {
            sqlite3_reset(statement)
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                row(Row(statement: statement))
            } else if result == SQLITE_DONE {
                return
            } else {
                throw StoreError(description: self.errorMessage + " (\(sql))")
            }
        }
    }

    public func scalarInt(_ sql: String, _ values: [Value] = []) throws -> Int64? {
        var result: Int64?
        try self.query(sql, values) { row in
            if !row.isNull(0) {
                result = row.int(0)
            }
        }
        return result
    }

    public func scalarDouble(_ sql: String, _ values: [Value] = []) throws -> Double? {
        var result: Double?
        try self.query(sql, values) { row in
            if !row.isNull(0) {
                result = row.double(0)
            }
        }
        return result
    }

    /// 記録の写しを作る（解析と学習用。整合した写しを 1 つのファイルに書く）
    public func snapshot(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try self.execute("VACUUM INTO ?", [.text(url.path)])
    }

    /// 消した行の内容がファイルに残らないようにする（WAL を書き戻して空にし、VACUUM で作り直し、もう一度 WAL を空にする）
    public func eraseFreedPages() throws {
        try self.executeScript("PRAGMA wal_checkpoint(TRUNCATE);")
        try self.executeScript("VACUUM;")
        try self.executeScript("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    public func transaction(_ body: () throws -> Void) throws {
        try self.executeScript("BEGIN")
        do {
            try body()
            try self.executeScript("COMMIT")
        } catch {
            try? self.executeScript("ROLLBACK")
            throw error
        }
    }
}

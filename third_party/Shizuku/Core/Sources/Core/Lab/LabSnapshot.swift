import Foundation
import SQLite3

// MARK: - 記録の写しを読む（llm-ime、解析と学習 段階 A）
//
// ShizukuLab は ConverterServer が作った写し（VACUUM INTO）を読み取り専用で開く。記録の本体（personal.sqlite）は開かない。

public enum LabSnapshot {
    /// 測定に必要な数だけを写しから読む。既存の表を使い、新しい記録は作らない。
    public static func readUpperBoundAuxiliary(url: URL) throws -> LabUpperBound.Auxiliary {
        var components = URLComponents()
        components.scheme = "file"; components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        var handle: OpaquePointer?
        guard sqlite3_open_v2(components.string, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw LabError.invalidResult("写しを開けない")
        }
        defer { sqlite3_close(db) }
        func query(_ sql: String, body: (OpaquePointer) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw LabError.invalidResult("写しの集計を読めない")
            }
            defer { sqlite3_finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW { body(statement); status = sqlite3_step(statement) }
            guard status == SQLITE_DONE else { throw LabError.invalidResult("写しの集計が途中で終わった") }
        }
        func text(_ statement: OpaquePointer, _ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var tables: Set<String> = []
        try query("SELECT name FROM sqlite_master WHERE type='table'") { tables.insert(text($0, 0)) }
        var result = LabUpperBound.Auxiliary()
        if tables.contains("rewrites") {
            try query("SELECT scene,COUNT(*) FROM rewrites GROUP BY scene ORDER BY scene") { row in
                let count = Int(sqlite3_column_int64(row, 1))
                result.rewrites[text(row, 0)] = count; result.totalRewrites += count
            }
        }
        if tables.contains("pauses") {
            try query("SELECT level,json FROM pauses ORDER BY level") { row in
                if let data = text(row, 1).data(using: .utf8), let histogram = try? JSONDecoder().decode(PersonalRhythm.Histogram.self, from: data) {
                    result.pauses[text(row, 0)] = histogram.total
                }
            }
            result.totalPauses = result.pauses["global"] ?? 0
        }
        if tables.contains("lexicon") {
            var phrases: [String: Set<String>] = [:]
            try query("SELECT scene,surface FROM lexicon WHERE count>=3 ORDER BY scene,surface") { row in
                let surface = text(row, 1)
                if (4...12).contains(surface.count) { phrases[text(row, 0), default: []].insert(surface) }
            }
            result.phrases = phrases.mapValues(\.count)
        }
        return result
    }

    /// 写しの確定をすべて、時刻の順に読む
    public static func readCommits(url: URL) throws -> [LabCommit] {
        var handle: OpaquePointer?
        // 写しは実行の間変わらないので immutable で開く（WAL の共有メモリのファイルを作らない・ロックしない）
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        let uri = components.string ?? url.path
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw LabError.invalidResult("写しを開けない")
        }
        defer {
            sqlite3_close(db)
        }
        var statement: OpaquePointer?
        var columns: OpaquePointer?
        var hasOrigin = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(commits)", -1, &columns, nil) == SQLITE_OK {
            while sqlite3_step(columns) == SQLITE_ROW {
                if sqlite3_column_text(columns, 1).map({ String(cString: $0) }) == "origin" { hasOrigin = true }
            }
        }
        sqlite3_finalize(columns)
        let sql = "SELECT ts, scene, kind, reading, surface, \"first\", \"left\", \(hasOrigin ? "origin" : "0") FROM commits ORDER BY ts, id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LabError.invalidResult("写しを読めない")
        }
        defer {
            sqlite3_finalize(statement)
        }
        func text(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        var commits: [LabCommit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            commits.append(LabCommit(
                ts: sqlite3_column_double(statement, 0), scene: text(1) ?? "", kind: text(2) ?? "", reading: text(3), surface: text(4) ?? "",
                first: text(5), left: text(6), origin: Int(sqlite3_column_int64(statement, 7))
            ))
        }
        return commits
    }
}

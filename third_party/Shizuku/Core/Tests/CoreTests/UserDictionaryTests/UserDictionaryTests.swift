@testable import Core
import Foundation
import Testing
#if os(macOS)
import SQLite3
#endif

@Test func testSystemUserDictionaryHelper() async throws {
    #if os(macOS)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: file) }
    var database: OpaquePointer?
    let opened = sqlite3_open(file.path, &database)
    #expect(opened == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, "CREATE TABLE ZTEXTREPLACEMENTENTRY(ZSHORTCUT TEXT, ZPHRASE TEXT); INSERT INTO ZTEXTREPLACEMENTENTRY VALUES('あいず','合成の辞書項目')", nil, nil, nil) == SQLITE_OK)
    let entries = try SystemUserDictionaryHelper.readEntries(databaseURL: file)
    #expect(entries.count == 1)
    #expect(entries.first?.shortcut == "あいず")
    #expect(entries.first?.phrase == "合成の辞書項目")
    #else
    await #expect(throws: SystemUserDictionaryHelper.FetchError.unsupportedOperatingSystem) {
        _ = try await SystemUserDictionaryHelper.fetchEntries()
    }
    #endif
}

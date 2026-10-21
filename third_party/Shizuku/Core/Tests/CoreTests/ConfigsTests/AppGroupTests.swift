import Foundation
import Testing

@testable import Core

#if os(macOS)
@Suite("AppGroup")
struct AppGroupTests {
    @Test("entitlementのないHelper向け共有コンテナURLを解決する")
    func resolveContainerURLFromHomeDirectory() {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(
            AppGroup.containerURL(homeDirectoryURL: homeDirectoryURL).path
                == "/Users/example/Library/Group Containers/YOURTEAMID.dev.tomonari.inputmethod.Shizuku"
        )
    }

    @Test("azooKey からの引き継ぎで、新しい側にない物だけを写す")
    func copyMissingItemsKeepsExistingFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AppGroupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("azooKey", isDirectory: true)
        let destination = root.appendingPathComponent("Shizuku", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("memory"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.appendingPathComponent("memory"), withIntermediateDirectories: true)
        try Data("old learning".utf8).write(to: source.appendingPathComponent("memory/learning.dat"))
        try Data("old dictionary".utf8).write(to: source.appendingPathComponent("memory/user.dat"))
        try Data("new dictionary".utf8).write(to: destination.appendingPathComponent("memory/user.dat"))

        AppGroup.copyMissingItems(from: source, to: destination, fileManager: fm)

        #expect(try String(contentsOf: destination.appendingPathComponent("memory/learning.dat"), encoding: .utf8) == "old learning")
        #expect(try String(contentsOf: destination.appendingPathComponent("memory/user.dat"), encoding: .utf8) == "new dictionary")
        #expect(fm.fileExists(atPath: source.appendingPathComponent("memory/learning.dat").path))
    }
}
#endif

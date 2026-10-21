import Foundation
import Security

enum BundleSecurity {
    static func isValid(_ url: URL, developmentOnly: Bool = false) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"YOURTEAMID\""
        if developmentOnly { text += " and certificate leaf[field.1.2.840.113635.100.6.1.2] exists" }
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }
}

/// 配布用のコンパイルには上書きのコードを含めない。開発用でも開発署名と専用マーカーが必要。
enum ManagerDevelopment {
    static let root: URL? = {
        #if MANAGER_DEVELOPMENT
        guard let path = ProcessInfo.processInfo.environment["LLM_IME_MANAGER_TEST_ROOT"] else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard path.hasPrefix("/"), root.path != "/", root != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".isolated-manager-test").path),
              BundleSecurity.isValid(Bundle.main.bundleURL, developmentOnly: true) else {
            fatalError("開発署名と専用の一時フォルダがないため、確認用の上書きを拒否しました")
        }
        return root
        #else
        return nil
        #endif
    }()
    static var isIsolated: Bool { root != nil }
}

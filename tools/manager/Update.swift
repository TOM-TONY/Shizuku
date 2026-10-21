import AppKit
import CryptoKit
import Security

// llm-ime 管理アプリ: アップデート。
//
// 配信元（GitHub Releases）の update.json を読み、今の通し番号（CFBundleVersion）より新しければ、管理アプリの zip
// （IME 本体を含む）をダウンロードして入れ替える。入れ替える前に次を確かめる:
//   1. zip の大きさと SHA-256 が update.json と同じ
//   2. update.json の署名（Ed25519。秘密鍵は配信する人の Mac のキーチェーンだけにある）が、管理アプリに埋め込んだ公開鍵で正しい
//   3. 展開したアプリが、同じチーム（Developer ID）の署名で、改ざんされていない。bundle ID と通し番号が update.json と同じ
// 通信するのはこの確認とダウンロードだけ（IME 本体は通信しない）。

struct UpdateInfo: Codable, Equatable {
    var version: String
    var build: Int64
    var url: String
    var size: Int64
    var sha256: String
    var signature: String
    var minimumSystemVersion: String?
    var notes: String?

    /// 署名する内容（通し番号・ダウンロード先・大きさ・ハッシュをまとめて守る）
    var signedMessage: Data {
        Data("llm-ime-update\n\(self.build)\n\(self.url)\n\(self.size)\n\(self.sha256)".utf8)
    }
}

enum Updater {
    static var currentVersion: BundleVersion? {
        BundleVersion(bundle: Bundle.main.bundleURL)
    }

    static func infoString(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 配信元。確認用に defaults の UpdateFeedURL で差し替えられる（https か、この Mac の http だけ）
    static var feedURL: URL? {
        let override = UserDefaults.standard.string(forKey: "UpdateFeedURL")
        guard let string = override ?? Self.infoString("LLMIMEUpdateFeedURL"), let url = URL(string: string) else {
            return nil
        }
        return Self.isAllowed(url) ? url : nil
    }

    static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? ""))
    }

    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let base64 = Self.infoString("LLMIMEUpdatePublicKey"), let data = Data(base64Encoded: base64) else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    static var teamID: String {
        Self.infoString("LLMIMETeamID") ?? "YOURTEAMID"
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// 新しい版があれば返す（なければ nil）。署名が正しくない update.json はエラーにする
    static func check() async throws -> UpdateInfo? {
        guard let feedURL = Self.feedURL else {
            throw ManagerError.message("アップデートの配信元が設定されていません。")
        }
        let (data, response) = try await Self.session().data(from: feedURL)
        guard let http = response as? HTTPURLResponse else {
            throw ManagerError.message("アップデートを確認できませんでした。")
        }
        guard http.statusCode == 200 else {
            throw ManagerError.message("アップデートを確認できませんでした（配信元の応答: \(http.statusCode)）。")
        }
        let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
        guard let key = Self.publicKey, let signature = Data(base64Encoded: info.signature),
              key.isValidSignature(signature, for: info.signedMessage) else {
            throw ManagerError.message("アップデートの情報の署名が正しくありません。入れずに中止しました。")
        }
        guard let current = Self.currentVersion, info.build > current.build else {
            return nil
        }
        if let minimum = info.minimumSystemVersion, let major = Int(minimum.split(separator: ".").first ?? ""),
           ProcessInfo.processInfo.operatingSystemVersion.majorVersion < major {
            throw ManagerError.message("新しい版（\(info.version)）には macOS \(minimum) 以降が必要です。")
        }
        return info
    }

    /// ダウンロードして確かめ、管理アプリと IME 本体を入れ替える。終わったら新しい管理アプリを開き直す
    static func apply(_ info: UpdateInfo, report: @escaping Installer.Report) async throws {
        guard let url = URL(string: info.url), Self.isAllowed(url) else {
            throw ManagerError.message("ダウンロード先が正しくありません。")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ime-update-\(info.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: work)
        }

        report("ダウンロードしています…", 0)
        let zip = work.appendingPathComponent("update.zip")
        try await Downloader(expectedSize: info.size) { fraction in
            report("ダウンロードしています（\(Int(fraction * 100))%）…", fraction * 0.8)
        }.download(url, to: zip)

        report("確かめています…", 0.8)
        let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == info.size, try Self.sha256(of: zip) == info.sha256.lowercased() else {
            throw ManagerError.message("ダウンロードしたファイルが壊れているか、配信元の情報と違います。入れずに中止しました。")
        }
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        guard Installer.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path]) == 0 else {
            throw ManagerError.message("ダウンロードしたファイルを展開できませんでした。")
        }
        let newApp = extracted.appendingPathComponent(managerAppName, isDirectory: true)
        let embedded = Paths.embeddedIME(in: newApp)
        guard let version = BundleVersion(bundle: newApp), version.build == info.build,
              Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              Bundle(url: embedded)?.bundleIdentifier == imeBundleID else {
            throw ManagerError.message("ダウンロードした物の中身が配信元の情報と違います。入れずに中止しました。")
        }
        guard Self.isSignedBySameTeam(newApp), Self.isSignedBySameTeam(embedded) else {
            throw ManagerError.message("ダウンロードした物の署名が正しくありません。入れずに中止しました。")
        }

        report("入れ替えています…", 0.9)
        Installer.removeQuarantine(newApp)
        try FileManager.default.createDirectory(at: Paths.applications, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: Paths.installedManager.path) {
            _ = try FileManager.default.replaceItemAt(Paths.installedManager, withItemAt: newApp)
        } else {
            try FileManager.default.moveItem(at: newApp, to: Paths.installedManager)
        }
        try Installer.installIME(from: Paths.embeddedIME(in: Paths.installedManager), report: report)
        BundledModels.prepare(report: report)
        // 自動確認の LaunchAgent が指す実行ファイルは同じ場所なので、そのままでよい
    }

    /// 同じチームの Developer ID（確認用の開発版では Apple Development）で署名され、中身が改ざんされていないか
    static func isSignedBySameTeam(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while true {
            let data = try autoreleasepool { try handle.read(upToCount: 8 * 1024 * 1024) ?? Data() }
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 新しい管理アプリを開き直して、この管理アプリは終わる
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--updated"]
        if let root = ManagerDevelopment.root { configuration.environment = ["LLM_IME_MANAGER_TEST_ROOT": root.path] }
        NSWorkspace.shared.openApplication(at: Paths.installedManager, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 自動確認

    /// 1 日 1 回の確認（画面なし）。新しい版があり、まだ知らせていなければ管理アプリを開く
    static func backgroundCheck() -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var found: UpdateInfo?
        Task.detached {
            found = try? await Self.check()
            semaphore.signal()
        }
        semaphore.wait()
        guard let info = found else {
            return 0
        }
        if ManagerDevelopment.isIsolated {
            print("確認用: 新しい版 \(info.build)（管理アプリは開きません）")
            return 0
        }
        let key = "LastNotifiedBuild"
        guard UserDefaults.standard.object(forKey: key) as? Int64 != info.build else {
            return 0
        }
        UserDefaults.standard.set(info.build, forKey: key)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Paths.installedManager, configuration: configuration) { _, _ in
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return 0
    }
}

/// 進み具合を知らせるダウンロード
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedSize: Int64
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    init(expectedSize: Int64, progress: @escaping (Double) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func download(_ url: URL, to destination: URL) async throws {
        self.destination = destination
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.expectedSize
        if total > 0 {
            self.progress(min(1, Double(totalBytesWritten) / Double(total)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination = self.destination else {
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            self.continuation?.resume(throwing: ManagerError.message("ダウンロードできませんでした（配信元の応答: \(http.statusCode)）。"))
            self.continuation = nil
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            self.continuation?.resume(returning: destination)
        } catch {
            self.continuation?.resume(throwing: error)
        }
        self.continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

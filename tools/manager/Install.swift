import AppKit
import Carbon
import CryptoKit

// Shizuku の管理アプリ: インストール・アンインストール（管理者権限なし。すべてユーザーのライブラリに入れる）
//
// - 管理アプリ  → ~/Applications/Shizuku.app（IME 本体を Contents/Helpers に含む。アップデートはこれを丸ごと入れ替える）
// - IME 本体    → ~/Library/Input Methods/Shizuku.app
// - 変換サーバー → ~/Library/LaunchAgents/<label>.plist（ログイン中のユーザーの launchd に登録して起動）
// - モデル      → ~/Library/Application Support/llm-ime/models/<名前>（DMG の .payload から。manifest.json に一覧）
// - 自動確認    → ~/Library/LaunchAgents/<updateCheckLabel>.plist（1 日 1 回、管理アプリをアップデートの確認だけで起動）

let serverLabel = "dev.tomonari.inputmethod.Shizuku.ConverterServer"
let updateCheckLabel = "dev.tomonari.llm-ime.updatecheck"
let imeBundleID = "dev.tomonari.inputmethod.Shizuku"
let imeAppName = "Shizuku.app"
let managerAppName = "Shizuku.app"

/// azooKey の名前で入れていた頃の物（入れ替えるときに取り除く。設定・学習データは IME が引き継ぐので残す）
enum LegacyInstall {
    static let serverLabel = "dev.tomonari.inputmethod.azooKeyMac.ConverterServer"
    static let imeBundleID = "dev.tomonari.inputmethod.azooKeyMac"
    static let imeAppName = "azooKeyMac.app"
    static let managerAppName = "azooKey llm-ime.app"
}

struct Manifest: Decodable {
    struct Model: Decodable, Identifiable {
        var id: String { name }
        var name: String
        var title: String
        var detail: String
        var bytes: Int64
        /// これ以上のメモリ（GB）がある Mac で最初から選ぶ
        var recommendedMemoryGB: Int
        /// 古い manifest にはない。必須のモデルはメモリや選択にかかわらず入れる。
        var required: Bool?
        var isRequired: Bool { required == true }
        /// 新しい DMG は署名済みの管理アプリ内のモデルを参照する。旧 manifest では nil。
        var bundled: Bool?
        var sha256: [String: String]?
    }
    var version: String
    var models: [Model]

    func recommendedModelNames(memoryGB: Int) -> Set<String> {
        Set(models.filter { $0.isRequired || memoryGB >= $0.recommendedMemoryGB }.map(\.name))
    }

    func selectedModels(_ names: Set<String>) -> [Model] {
        models.filter { $0.isRequired || names.contains($0.name) }
    }
}

enum Paths {
    static let home = ManagerDevelopment.root ?? FileManager.default.homeDirectoryForCurrentUser
    static let applications = home.appendingPathComponent("Applications", isDirectory: true)
    static let installedManager = applications.appendingPathComponent(managerAppName, isDirectory: true)
    static let inputMethods = home.appendingPathComponent("Library/Input Methods", isDirectory: true)
    static let installedIME = inputMethods.appendingPathComponent(imeAppName, isDirectory: true)
    static let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    static let serverPlist = launchAgents.appendingPathComponent("\(serverLabel).plist")
    static let updateCheckPlist = launchAgents.appendingPathComponent("\(updateCheckLabel).plist")
    static let models = home.appendingPathComponent("Library/Application Support/llm-ime/models", isDirectory: true)
    static var serverExecutable: URL {
        installedIME.appendingPathComponent("Contents/Helpers/ConverterServer/ConverterServer")
    }

    /// 管理アプリ（app）の中の IME 本体
    static func embeddedIME(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Helpers/\(imeAppName)", isDirectory: true)
    }

    /// DMG のモデルの置き場所。管理アプリの隣の .payload。見つからなければ（隔離された場所から起動された場合など）
    /// マウント中のディスクイメージから探す
    static func payload() -> URL? {
        let fm = FileManager.default
        var candidates = [Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".payload", isDirectory: true)]
        if let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
            candidates += volumes.map { $0.appendingPathComponent(".payload", isDirectory: true) }
        }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    /// この管理アプリが ~/Applications に入っている物か（DMG から開いた物ではないか）
    static var isRunningInstalledCopy: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == installedManager.standardizedFileURL.path
    }
}

enum ManagerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self {
            return text
        }
        return nil
    }
}

struct SystemInfo {
    let isAppleSilicon: Bool
    let osOK: Bool
    let memoryGB: Int
    let freeBytes: Int64

    static func current() -> SystemInfo {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isArm = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let memory = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let free = (try? Paths.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return SystemInfo(isAppleSilicon: isArm, osOK: os.majorVersion >= 15, memoryGB: memory, freeBytes: free)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// bundle の版（CFBundleShortVersionString）と通し番号（CFBundleVersion）
struct BundleVersion {
    var version: String
    var build: Int64

    init?(bundle url: URL) {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else {
            return nil
        }
        self.version = info["CFBundleShortVersionString"] as? String ?? "?"
        self.build = Int64(info["CFBundleVersion"] as? String ?? "") ?? 0
    }
}

enum Installer {
    typealias Report = @Sendable (String, Double) -> Void

    /// DMG からのインストール: 管理アプリを ~/Applications に写し、その中の IME 本体と選んだモデルを入れる
    static func installFromDMG(payload: URL, models: [Manifest.Model], autoCheck: Bool, report: Report) throws {
        let fm = FileManager.default
        report("動いている IME を止めています…", 0)
        stopServices()

        report("管理アプリを入れています…", 0)
        try fm.createDirectory(at: Paths.applications, withIntermediateDirectories: true)
        if Bundle.main.bundleURL.standardizedFileURL != Paths.installedManager.standardizedFileURL {
            if fm.fileExists(atPath: Paths.installedManager.path) {
                try fm.removeItem(at: Paths.installedManager)
            }
            try fm.copyItem(at: Bundle.main.bundleURL, to: Paths.installedManager)
            removeQuarantine(Paths.installedManager)
        }

        try copyModels(from: payload, models: models.filter { $0.bundled != true }, report: report)
        if models.contains(where: { $0.bundled == true }) {
            try BundledModels.install(report: report)
        }
        try installIME(from: Paths.embeddedIME(in: Paths.installedManager), report: report)
        try setAutoUpdateCheck(autoCheck)
    }

    /// IME 本体を入れ替えて、変換サーバーを登録・起動する（隔離属性は外す。公証済みなので、システムが入力メソッドとして読み込めるように）
    static func installIME(from source: URL, report: Report) throws {
        let fm = FileManager.default
        report("IME 本体を入れています…", 1)
        stopServices()
        removeLegacyInstall()
        try fm.createDirectory(at: Paths.inputMethods, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Paths.installedIME.path) {
            try fm.removeItem(at: Paths.installedIME)
        }
        try fm.copyItem(at: source, to: Paths.installedIME)
        removeQuarantine(Paths.installedIME)

        report("変換サーバーを登録しています…", 1)
        try fm.createDirectory(at: Paths.launchAgents, withIntermediateDirectories: true)
        try writePlist([
            "Label": serverLabel,
            "ProgramArguments": [Paths.serverExecutable.path],
            "MachServices": [serverLabel: true],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": "/tmp/\(serverLabel).stdout.log",
            "StandardErrorPath": "/tmp/\(serverLabel).stderr.log",
        ], to: Paths.serverPlist)
        let domain = "gui/\(getuid())"
        run("/bin/launchctl", ["bootstrap", domain, Paths.serverPlist.path])
        guard run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(serverLabel)"]) == 0 else {
            throw ManagerError.message("変換サーバーを起動できませんでした。いったんログアウトしてから、もう一度お試しください。")
        }
        // 入力ソースの一覧に出るようにする（追加はユーザーがシステム設定で行う）
        if !ManagerDevelopment.isIsolated { TISRegisterInputSource(Paths.installedIME as CFURL) }
    }

    /// 選んだモデルを写す（同じ物がすでにあれば飛ばす）
    @discardableResult
    static func copyModels(from payload: URL, models: [Manifest.Model], to directory: URL = Paths.models, report: Report) throws -> Bool {
        let fm = FileManager.default
        let total = max(1, models.map(\.bytes).reduce(0, +))
        var done: Int64 = 0
        var changed = false
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for model in models {
            let source = payload.appendingPathComponent("models/\(model.name)", isDirectory: true)
            let destination = directory.appendingPathComponent(model.name, isDirectory: true)
            let temporary = directory.appendingPathComponent(".\(model.name).installing", isDirectory: true)
            let identical = model.sha256.map { ModelFiles.matches(destination, hashes: $0, allowingExtraFiles: true) } ?? sameContents(source, destination)
            if !fm.fileExists(atPath: temporary.path), identical {
                done += model.bytes
                report("\(model.title) はすでに入っています", Double(done) / Double(total))
                continue
            }
            if fm.fileExists(atPath: temporary.path) {
                try fm.removeItem(at: temporary)
            }
            let base = done
            try copyTree(from: source, to: temporary) { copied in
                report("\(model.title) を入れています（\(formatBytes(base + copied)) / \(formatBytes(total))）", Double(base + copied) / Double(total))
            }
            if let hashes = model.sha256, !ModelFiles.matches(temporary, hashes: hashes) {
                throw ManagerError.message("コピーしたモデルの内容を確認できませんでした: \(model.name)")
            }
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: temporary, to: destination)
            changed = true
            done += model.bytes
        }
        return changed
    }

    static func uninstall(removeModels: Bool) throws {
        let fm = FileManager.default
        stopServices()
        try setAutoUpdateCheck(false)
        for url in [Paths.serverPlist, Paths.installedIME] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        if removeModels {
            try Self.removeModels()
        }
        // 管理アプリ自身は、終了後に消す（動いている間は消せないため）
        if fm.fileExists(atPath: Paths.installedManager.path) {
            let script = "sleep 2; /bin/rm -rf \"\(Paths.installedManager.path)\""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try? process.run()
        }
    }

    /// モデルだけを取り除く。確認では一時フォルダを渡し、IME や LaunchAgent に触れずに実行する。
    static func removeModels(at directory: URL = Paths.models) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// 1 日 1 回のアップデートの確認（管理アプリを --background-check で起動する LaunchAgent）を入れる・外す
    static func setAutoUpdateCheck(_ enabled: Bool) throws {
        let fm = FileManager.default
        let domain = "gui/\(getuid())"
        run("/bin/launchctl", ["bootout", "\(domain)/\(updateCheckLabel)"])
        if fm.fileExists(atPath: Paths.updateCheckPlist.path) {
            try fm.removeItem(at: Paths.updateCheckPlist)
        }
        guard enabled else {
            return
        }
        try fm.createDirectory(at: Paths.launchAgents, withIntermediateDirectories: true)
        try writePlist([
            "Label": updateCheckLabel,
            "ProgramArguments": [Paths.installedManager.appendingPathComponent("Contents/MacOS/Manager").path, "--background-check"],
            "StartInterval": 86400,
            "RunAtLoad": false,
        ], to: Paths.updateCheckPlist)
        run("/bin/launchctl", ["bootstrap", domain, Paths.updateCheckPlist.path])
    }

    static var isAutoUpdateCheckEnabled: Bool {
        FileManager.default.fileExists(atPath: Paths.updateCheckPlist.path)
    }

    static func stopServices() {
        if ManagerDevelopment.isIsolated { return }
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(serverLabel)"])
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: imeBundleID) {
            app.forceTerminate()
        }
    }

    /// azooKey の名前で入れていた IME 本体・変換サーバー・管理アプリを取り除く（入力ソースの一覧からも消える）
    static func removeLegacyInstall() {
        if ManagerDevelopment.isIsolated { return }
        let fm = FileManager.default
        let legacyServerPlist = Paths.launchAgents.appendingPathComponent("\(LegacyInstall.serverLabel).plist")
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(LegacyInstall.serverLabel)"])
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: LegacyInstall.imeBundleID) {
            app.forceTerminate()
        }
        let legacyItems = [
            legacyServerPlist,
            Paths.inputMethods.appendingPathComponent(LegacyInstall.imeAppName, isDirectory: true),
            Paths.applications.appendingPathComponent(LegacyInstall.managerAppName, isDirectory: true),
        ]
        for url in legacyItems where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    static func removeQuarantine(_ url: URL) {
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }

    static func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Int32 {
        if ManagerDevelopment.isIsolated && path == "/bin/launchctl" {
            print("確認用: launchctl \(arguments.joined(separator: " "))（実行しません）")
            return 0
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// ファイルの一覧と大きさが同じなら、同じ物とみなす
    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        func listing(_ root: URL) -> [String: Int64]? {
            guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
                return nil
            }
            var result: [String: Int64] = [:]
            for case let relative as String in enumerator {
                let url = root.appendingPathComponent(relative)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else {
                    continue
                }
                result[relative] = Int64(values.fileSize ?? 0)
            }
            return result
        }
        guard FileManager.default.fileExists(atPath: b.path), let la = listing(a), let lb = listing(b) else {
            return false
        }
        return la == lb
    }

    /// フォルダを丸ごと写す。大きなファイルは 8MB ずつ写して、写した量を 256MB ごとに知らせる
    static func copyTree(from source: URL, to destination: URL, progress: (Int64) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // 相対パスを列挙する。URL の列挙では /var が /private/var に展開されることがあり、文字数で切ると壊れる。
        guard let enumerator = fm.enumerator(atPath: source.path) else {
            throw ManagerError.message("モデルを読めませんでした: \(source.lastPathComponent)")
        }
        var copied: Int64 = 0
        var reported: Int64 = 0
        let chunk = 8 * 1024 * 1024
        for case let relative as String in enumerator {
            let url = source.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }
            fm.createFile(atPath: target.path, contents: nil)
            let input = try FileHandle(forReadingFrom: url)
            let output = try FileHandle(forWritingTo: target)
            defer {
                try? input.close()
                try? output.close()
            }
            while true {
                let data = try autoreleasepool { try input.read(upToCount: chunk) ?? Data() }
                if data.isEmpty {
                    break
                }
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                if copied - reported >= 256 * 1024 * 1024 {
                    reported = copied
                    progress(copied)
                }
            }
        }
    }
}

enum ModelFiles {
    /// コピー元は組も一致させる。配置先では余分な通常ファイルを無視できる。リンク・絶対パス・親への移動は認めない。
    static func matches(_ directory: URL, hashes: [String: String], allowingExtraFiles: Bool = false) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard !hashes.isEmpty,
              hashes.keys.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }),
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let entries = fm.enumerator(atPath: directory.path) else { return false }
        var found: Set<String> = []
        for case let relative as String in entries {
            let file = directory.appendingPathComponent(relative)
            guard let info = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]), info.isSymbolicLink != true else { return false }
            guard info.isRegularFile == true else { continue }
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return false }
            guard let expected = hashes[relative] else {
                if allowingExtraFiles { continue }
                return false
            }
            guard let input = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? input.close() }
            var digest = SHA256()
            do {
                while let data = try input.read(upToCount: 8 * 1024 * 1024), !data.isEmpty { digest.update(data: data) }
            } catch { return false }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { return false }
            found.insert(relative)
        }
        return found == Set(hashes.keys)
    }
}

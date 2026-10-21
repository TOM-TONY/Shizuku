import Foundation

public enum AppGroup {
    /// チームID接頭辞の App Group。
    ///
    /// macOS 15 以降、`group.` で始まる App Group はプロビジョニングプロファイルで許可された
    /// アプリしか共有コンテナを読み書きできない。プロファイルを埋め込めない ConverterServer
    /// （app bundle 内の単体実行ファイル）は cfprefsd に書き込みを拒否され、設定・学習データを
    /// 共有できなかった。チームID接頭辞の App Group は署名のチームIDで検証されるため、
    /// 同じチームで署名した ConverterServer からも利用できる。
    public static let identifier = "YOURTEAMID.dev.tomonari.inputmethod.Shizuku"

    /// 移行元: azooKey の名前で配っていた頃の App Group・設定キーの接頭辞・データのフォルダ名
    static let legacyIdentifier = "YOURTEAMID.dev.tomonari.inputmethod.azooKeyMac"
    static let legacyPreferenceKeyPrefix = "dev.tomonari.inputmethod.azooKeyMac."
    static let legacyDirectoryName = "azooKey"

    static let preferenceKeyPrefix = "dev.tomonari.inputmethod.Shizuku."
    static let directoryName = "Shizuku"

    #if os(macOS)
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        if let root = WindowContextTestRuntime.root { return root.appendingPathComponent("storage", isDirectory: true) }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.identifier)
            ?? Self.containerURL(homeDirectoryURL: fileManager.homeDirectoryForCurrentUser)
    }

    /// App Group entitlementを持たない同一ユーザーのHelperから共有コンテナを参照するためのURL。
    ///
    /// ConverterServerはsandboxed appではなくLaunchAgentなので、FileManagerのApp Group APIは
    /// `nil`を返す。その場合もクライアントと同じデータを使えるよう、macOSで定義された
    /// ユーザー単位のGroup Containers配下を明示的に解決する。
    public static func containerURL(homeDirectoryURL: URL) -> URL {
        Self.containerURL(identifier: Self.identifier, homeDirectoryURL: homeDirectoryURL)
    }

    static func containerURL(identifier: String, homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    public static func applicationSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let containerURL = Self.containerURL(fileManager: fileManager) {
            return containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        }

        if #available(macOS 13, *) {
            return URL.applicationSupportDirectory
                .appending(path: Self.directoryName, directoryHint: .isDirectory)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public static func memoryDirectoryURL(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("memory", isDirectory: true)
    }

    private static let preferenceMigrationDoneKey = "dev.tomonari.inputmethod.Shizuku.migration.preferencesFromAzooKey"
    private static let dataMigrationDoneKey = "dev.tomonari.inputmethod.Shizuku.migration.dataFromAzooKey"

    /// azooKey の名前だった頃の設定（ユーザ辞書を含む）を Shizuku へ一度だけ引き継ぐ。
    ///
    /// 旧 App Group の `dev.tomonari.inputmethod.azooKeyMac.*` を `dev.tomonari.inputmethod.Shizuku.*` に写す。
    /// IME 本体（旧グループの entitlement を持つ）と ConverterServer（同じチームの署名で読める）の両方が、
    /// 設定を読む前に呼ぶ。新しい側にすでにある値は上書きしない。
    public static func migratePreferencesFromAzooKeyIfNeeded() {
        guard WindowContextTestRuntime.root == nil else { return }
        guard let newDefaults = UserDefaults(suiteName: Self.identifier),
              !newDefaults.bool(forKey: Self.preferenceMigrationDoneKey) else {
            return
        }
        if let legacyDefaults = UserDefaults(suiteName: Self.legacyIdentifier) {
            for (key, value) in legacyDefaults.dictionaryRepresentation() where key.hasPrefix(Self.legacyPreferenceKeyPrefix) {
                let newKey = Self.preferenceKeyPrefix + key.dropFirst(Self.legacyPreferenceKeyPrefix.count)
                if newDefaults.object(forKey: newKey) == nil {
                    newDefaults.set(value, forKey: newKey)
                }
            }
        }
        newDefaults.set(true, forKey: Self.preferenceMigrationDoneKey)
    }

    /// azooKey の名前だった頃のデータ（学習・変換用のユーザ辞書など）を Shizuku へ一度だけ引き継ぐ。
    ///
    /// 旧コンテナの `Library/Application Support/azooKey` を新コンテナの `…/Shizuku` に写す。
    /// データを使う ConverterServer（sandbox の外で動く）が、データに触れる前に呼ぶ。
    /// sandbox の中の IME 本体からは旧コンテナが見えないことがあるので、IME 本体では呼ばない。
    public static func migrateDataFromAzooKeyIfNeeded(fileManager: FileManager = .default) {
        guard WindowContextTestRuntime.root == nil else { return }
        guard let newDefaults = UserDefaults(suiteName: Self.identifier),
              !newDefaults.bool(forKey: Self.dataMigrationDoneKey),
              let newContainer = Self.containerURL(fileManager: fileManager) else {
            return
        }
        let legacyContainer = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.legacyIdentifier)
            ?? Self.containerURL(identifier: Self.legacyIdentifier, homeDirectoryURL: fileManager.homeDirectoryForCurrentUser)
        let applicationSupport = "Library/Application Support"
        Self.copyMissingItems(
            from: legacyContainer
                .appendingPathComponent(applicationSupport, isDirectory: true)
                .appendingPathComponent(Self.legacyDirectoryName, isDirectory: true),
            to: newContainer
                .appendingPathComponent(applicationSupport, isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true),
            fileManager: fileManager
        )
        newDefaults.set(true, forKey: Self.dataMigrationDoneKey)
    }

    /// `source` の中身のうち、`destination` にまだないものだけを写す（フォルダは中まで見る）。
    static func copyMissingItems(from source: URL, to destination: URL, fileManager: FileManager) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            return
        }
        guard fileManager.fileExists(atPath: destination.path) else {
            try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.copyItem(at: source, to: destination)
            return
        }
        guard isDirectory.boolValue,
              let children = try? fileManager.contentsOfDirectory(atPath: source.path) else {
            return
        }
        for child in children {
            Self.copyMissingItems(
                from: source.appendingPathComponent(child),
                to: destination.appendingPathComponent(child),
                fileManager: fileManager
            )
        }
    }
    #endif
}

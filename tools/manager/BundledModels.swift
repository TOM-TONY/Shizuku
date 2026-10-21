import Foundation

/// コピー元は実行中の管理アプリ内だけ。署名・構成・ハッシュを確認して共通のコピー処理に渡す。
enum BundledModels {
    static let name = "ruri-v3-30m-coreml"
    static let source = "cl-nagoya/ruri-v3-30m@24899e5de370b56d179604a007c0d727bf144504"

    /// 既存の管理・更新操作を続け、不足分は次の起動でもう一度試す。
    @discardableResult
    static func prepare(report: Installer.Report) -> String? {
        do {
            try Self.install(report: report)
            return nil
        } catch {
            let warning = "解析と学習の埋め込みモデルを準備できませんでした。次回の起動時に再試行します。"
            NSLog("llm-ime: %@ %@", warning, error.localizedDescription)
            report("警告: \(warning)（\(error.localizedDescription)）", 1)
            return warning
        }
    }

    @discardableResult
    static func install(report: Installer.Report) throws -> Bool {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let payload = app.appendingPathComponent("Contents/Resources/ModelPayload", isDirectory: true)
        guard payload.resolvingSymlinksInPath().path.hasPrefix(app.path + "/"),
              Bundle.main.bundleIdentifier == "dev.tomonari.llm-ime.manager" else {
            throw ManagerError.message("管理アプリの中にあるモデルを確認できませんでした。")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: payload.appendingPathComponent("manifest.json")))
        guard manifest.models.count == 1, let model = manifest.models.first, model.name == Self.name,
              model.isRequired, let hashes = model.sha256,
              hashes["embedding.json"] != nil, hashes["tokenizer.json"] != nil,
              hashes.keys.contains(where: { $0.hasPrefix("embedder.mlmodelc/") }) else {
            throw ManagerError.message("管理アプリに含まれる埋め込みモデルの説明が不完全です。")
        }
        let destination = Paths.models.appendingPathComponent(Self.name)
        let temporary = Paths.models.appendingPathComponent(".\(Self.name).installing")
        if !fm.fileExists(atPath: temporary.path), ModelFiles.matches(destination, hashes: hashes, allowingExtraFiles: true) {
            report("\(model.title) はすでに入っています", 1)
            return false
        }
        guard BundleSecurity.isValid(app),
              payload.appendingPathComponent("manifest.json").resolvingSymlinksInPath().path.hasPrefix(payload.path + "/") else {
            throw ManagerError.message("管理アプリの署名が正しくありません。モデルを入れずに中止しました。")
        }
        let directory = payload.appendingPathComponent("models/\(Self.name)")
        guard directory.resolvingSymlinksInPath().path.hasPrefix(payload.path + "/"), ModelFiles.matches(directory, hashes: hashes),
              let info = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("embedding.json"))) as? [String: Any],
              info["source"] as? String == Self.source, info["license"] as? String == "apache-2.0" else {
            throw ManagerError.message("同梱の埋め込みモデルが欠けているか、出典・ライセンス・内容が違います。")
        }
        let changed = try Installer.copyModels(from: payload, models: [model], report: report)
        if changed, fm.fileExists(atPath: Paths.serverPlist.path) {
            // 話題の知識はサーバーの起動時に読み直す。入力メソッドのクライアントは止めない。
            guard Installer.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(serverLabel)"]) == 0 else {
                throw ManagerError.message("モデルは入りましたが、変換サーバーを再起動できませんでした。")
            }
        }
        return changed
    }
}

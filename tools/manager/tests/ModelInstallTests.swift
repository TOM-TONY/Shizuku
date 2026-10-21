import Foundation
import CryptoKit

// swiftc -parse-as-library tools/manager/{BundleSupport,BundledModels,Install}.swift tools/manager/tests/ModelInstallTests.swift -o build/model-install-tests
// build/model-install-tests [DMG の .payload]（指定すると本物の埋め込みも一時フォルダに写して確認する）
@main
enum ModelInstallTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ManagerError.message(message) }
    }

    static func main() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("model-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let old = Data("""
        {"version":"old","models":[{"name":"gemma4-e2b-ane","title":"E2B","detail":"optional","bytes":8,"recommendedMemoryGB":8}]}
        """.utf8)
        let legacy = try JSONDecoder().decode(Manifest.self, from: old)
        try require(!legacy.models[0].isRequired && legacy.models[0].required == nil, "old manifest")
        try require(legacy.selectedModels([]).isEmpty, "old manifest selection")
        try require(legacy.recommendedModelNames(memoryGB: 8) == ["gemma4-e2b-ane"], "old memory recommendation")
        print("PASS: old manifest and memory recommendation")

        let data = Data("""
        {"version":"new","models":[
          {"name":"gemma4-e2b-ane","title":"E2B","detail":"optional","bytes":8,"recommendedMemoryGB":8,"required":false},
          {"name":"ruri-v3-30m-coreml","title":"Ruri","detail":"required","bytes":77,"recommendedMemoryGB":999,"required":true}
        ]}
        """.utf8)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let required = "ruri-v3-30m-coreml"
        try require(manifest.recommendedModelNames(memoryGB: 0) == [required], "required bypasses memory")
        try require(manifest.selectedModels([]).map(\.name) == [required], "required bypasses empty selection")
        try require(manifest.selectedModels(["unknown"]).map(\.name) == [required], "required bypasses explicit selection")
        try require(manifest.selectedModels(["gemma4-e2b-ane"]).map(\.bytes).reduce(0, +) == 85, "total includes required bytes")
        try require(manifest.selectedModels(Set(manifest.models.map(\.name))).count == 2, "CLI default keeps all models")
        print("PASS: required selection, CLI defaults and byte total")

        let payload = work.appendingPathComponent(".payload")
        let source = payload.appendingPathComponent("models/\(required)")
        try fm.createDirectory(at: source.appendingPathComponent("embedder.mlmodelc"), withIntermediateDirectories: true)
        try Data("metadata".utf8).write(to: source.appendingPathComponent("embedding.json"))
        try Data("tokenizer".utf8).write(to: source.appendingPathComponent("tokenizer.json"))
        try Data("weights".utf8).write(to: source.appendingPathComponent("embedder.mlmodelc/weights.bin"))
        let directory = work.appendingPathComponent("home/Library/Application Support/llm-ime/models")
        let models = manifest.selectedModels([])
        try Installer.copyModels(from: payload, models: models, to: directory, report: { _, _ in })
        let installed = directory.appendingPathComponent(required)
        try require(Installer.sameContents(source, installed), "copy at expected model path")
        print("PASS: copyModels to temporary home")

        let tokenizer = installed.appendingPathComponent("tokenizer.json")
        let sentinel = Date(timeIntervalSince1970: 1_000_000)
        try fm.setAttributes([.modificationDate: sentinel], ofItemAtPath: tokenizer.path)
        try Installer.copyModels(from: payload, models: models, to: directory, report: { _, _ in })
        let date = try fm.attributesOfItem(atPath: tokenizer.path)[.modificationDate] as? Date
        try require(date == sentinel, "identical model must not be copied again")
        print("PASS: identical model skipped")

        try Data("different size".utf8).write(to: tokenizer)
        let temporary = directory.appendingPathComponent(".\(required).installing")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: temporary.appendingPathComponent("stale"))
        try Installer.copyModels(from: payload, models: models, to: directory, report: { _, _ in })
        try require(Installer.sameContents(source, installed) && !fm.fileExists(atPath: temporary.path), "replace incomplete copy")
        print("PASS: incomplete model and stale staging replaced")

        var verified = models[0]
        verified.sha256 = try Dictionary(uniqueKeysWithValues: ["embedding.json", "tokenizer.json", "embedder.mlmodelc/weights.bin"].map {
            ($0, SHA256.hash(data: try Data(contentsOf: source.appendingPathComponent($0))).map { String(format: "%02x", $0) }.joined())
        })
        try require(ModelFiles.matches(installed, hashes: verified.sha256!), "valid hashes")
        try Data("TOKENIZER".utf8).write(to: tokenizer) // 同じ9バイトでも内容は違う
        try require(!ModelFiles.matches(installed, hashes: verified.sha256!), "same-size corruption")
        try Installer.copyModels(from: payload, models: [verified], to: directory, report: { _, _ in })
        try require(ModelFiles.matches(installed, hashes: verified.sha256!), "repair corrupted content")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let changed = try Installer.copyModels(from: payload, models: [verified], to: directory, report: { _, _ in })
        try require(changed && !fm.fileExists(atPath: temporary.path), "stale staging with a complete model")
        print("PASS: same-size corruption and interrupted installation repaired")

        let extra = installed.appendingPathComponent(".DS_Store")
        try Data("Finder".utf8).write(to: extra)
        try fm.setAttributes([.modificationDate: sentinel], ofItemAtPath: tokenizer.path)
        try require(!ModelFiles.matches(installed, hashes: verified.sha256!), "source check remains strict")
        try require(ModelFiles.matches(installed, hashes: verified.sha256!, allowingExtraFiles: true), "destination ignores extra files")
        let recopied = try Installer.copyModels(from: payload, models: [verified], to: directory, report: { _, _ in })
        try require(!recopied && fm.fileExists(atPath: extra.path), "extra files must not cause copying")
        let unchanged = try fm.attributesOfItem(atPath: tokenizer.path)[.modificationDate] as? Date
        try require(unchanged == sentinel, "extra files preserve installed weights")
        let link = installed.appendingPathComponent("extra-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent("tokenizer.json"))
        try require(!ModelFiles.matches(installed, hashes: verified.sha256!, allowingExtraFiles: true), "extra links remain rejected")
        try fm.removeItem(at: link)
        try require(!ModelFiles.matches(installed, hashes: ["../tokenizer.json": "x"], allowingExtraFiles: true), "parent traversal rejected")
        try require(!ModelFiles.matches(installed, hashes: ["/tokenizer.json": "x"], allowingExtraFiles: true), "absolute path rejected")
        print("PASS: extra destination files skipped; strict source, links and unsafe paths rejected")

        // この試験の実行ファイルは管理アプリではないので、実環境に触れる前に配置元の確認で失敗する。
        try require(BundledModels.prepare(report: { _, _ in }) != nil, "preparation failure returns a warning")
        try require(BundledModels.prepare(report: { _, _ in }) != nil, "preparation can retry without terminating")
        print("PASS: preparation failure continues and retries")

        if CommandLine.arguments.count > 1 {
            let realPayload = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let realManifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: realPayload.appendingPathComponent("manifest.json")))
            let realModels = realManifest.selectedModels([])
            try require(realModels.map(\.name) == [required], "DMG embedding must be required")
            if realModels[0].bundled == true { try require(CommandLine.arguments.count > 2, "pass the bundled ModelPayload as second argument") }
            let realSource = realModels[0].bundled == true ? URL(fileURLWithPath: CommandLine.arguments[2]) : realPayload
            try Installer.copyModels(from: realSource, models: realModels, to: directory, report: { message, _ in print(message) })
            try require(Installer.sameContents(realSource.appendingPathComponent("models/\(required)"), installed), "real embedding copied")
            try Installer.copyModels(from: realSource, models: realModels, to: directory, report: { message, _ in print(message) })
            print("PASS: DMG embedding copied and repeated install skipped (\(realModels[0].bytes) bytes)")
        }

        let sibling = directory.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        try Installer.removeModels(at: directory)
        try require(!fm.fileExists(atPath: installed.path) && !fm.fileExists(atPath: directory.path), "uninstall removes embedding with models")
        try require(fm.fileExists(atPath: sibling.path), "uninstall preserves files outside model directory")
        try Installer.removeModels(at: directory)
        print("PASS: model removal, absent directory and unrelated file preserved")
    }
}

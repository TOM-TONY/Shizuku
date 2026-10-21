import Foundation
import Testing
@testable import Core

@Test func modelCatalogClassifiesFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ime-catalog-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    func make(_ folder: String, files: [String: String], directories: [String] = []) throws {
        let url = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: url.appendingPathComponent(name))
        }
        for name in directories {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
    }
    // 続き予測（ANE）
    try make("gemma4-e4b-ane", files: ["meta.json": "{}", "host.json": "{}", "tokenizer.bin": "x"], directories: ["lm_head.mlmodelc"])
    // いい感じ変換（MLX）: 使える
    try make("Qwen3-8B-4bit", files: [
        "config.json": #"{"model_type": "qwen3", "quantization": {"bits": 4}}"#,
        "model.safetensors": "x", "tokenizer.json": "{}", "tokenizer_config.json": #"{"chat_template": "x"}"#,
    ])
    // 対応していない形式
    try make("unknown-model", files: ["config.json": #"{"model_type": "foo"}"#, "model.safetensors": "x", "tokenizer.json": "{}"])
    // チャットテンプレートがない（指示に答えるモデルではない）
    try make("base-model", files: ["config.json": #"{"model_type": "llama"}"#, "model.safetensors": "x", "tokenizer.json": "{}", "tokenizer_config.json": "{}"])
    // モデルではないフォルダ
    try make("notes", files: ["readme.txt": "x"])

    let models = ModelCatalog.models(in: root)
    #expect(models.count == 4)
    let completion = try #require(models.first { $0.name == "gemma4-e4b-ane" })
    #expect(completion.kind == .completion && completion.isUsable && completion.displayName == "Gemma 4 E4B")
    let qwen = try #require(models.first { $0.name == "Qwen3-8B-4bit" })
    #expect(qwen.kind == .chat && qwen.isUsable && qwen.detail.hasPrefix("4bit"))
    #expect(models.first { $0.name == "unknown-model" }?.isUsable == false)
    #expect(models.first { $0.name == "base-model" }?.isUsable == false)
    #expect(ModelCatalog.models(kind: .chat, in: root).allSatisfy { $0.kind == .chat })
}

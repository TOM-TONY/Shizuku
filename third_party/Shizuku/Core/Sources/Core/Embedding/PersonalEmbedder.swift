import CoreML
import Foundation

// MARK: - 文の埋め込み（llm-ime、解析と学習 段階 B）
//
// ruri-v3 を公式の重みから Core ML に変換したもの（tools/embedding/convert_ruri_coreml.py。入力の長さは固定、平均プーリングと
// L2 正規化まで含む）を読み、文を単位長のベクトルにする。キーの処理の流れには載せない（確定のたびに裏で作る・解析でまとめて作る）。

public final class PersonalEmbedder: @unchecked Sendable {
    public let tokenizer: UnigramTokenizer
    private let model: MLModel
    public let length: Int
    /// 文の前に付ける言葉（ruri-v3 は "検索クエリ: " / "検索文書: "。使うかは答え合わせで決める）
    public var queryPrefix: String
    public var documentPrefix: String
    private let lock = NSLock()

    /// - Parameters:
    ///   - modelURL: 変換した .mlpackage または コンパイル済みの .mlmodelc
    ///   - tokenizerURL: tokenizer.json
    public init(modelURL: URL, tokenizerURL: URL, length: Int, computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
                queryPrefix: String = "", documentPrefix: String = "") throws {
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.model = try MLModel(contentsOf: compiled, configuration: configuration)
        self.tokenizer = try UnigramTokenizer(tokenizerJSON: tokenizerURL)
        self.length = length
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
    }

    /// ModelCatalog の文の埋め込みのフォルダ（embedding.json・tokenizer.json・embedder.mlmodelc）から読む
    public convenience init(directory: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        guard let info = ModelCatalog.embeddingInfo(at: directory) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(
            modelURL: directory.appendingPathComponent("embedder.mlmodelc", isDirectory: true),
            tokenizerURL: directory.appendingPathComponent("tokenizer.json"), length: info.length, computeUnits: computeUnits,
            queryPrefix: info.queryPrefix, documentPrefix: info.documentPrefix
        )
    }

    /// 文を単位長のベクトルにする（失敗したら nil）
    public func embed(_ text: String, asQuery: Bool) -> [Float]? {
        let encoded = self.tokenizer.encode((asQuery ? self.queryPrefix : self.documentPrefix) + text, length: self.length)
        guard let ids = try? MLMultiArray(shape: [1, NSNumber(value: self.length)], dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: self.length)], dataType: .int32) else {
            return nil
        }
        for index in 0..<self.length {
            ids[index] = NSNumber(value: encoded.ids[index])
            mask[index] = NSNumber(value: encoded.mask[index])
        }
        let provider = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        guard let provider else {
            return nil
        }
        let output: MLFeatureProvider? = self.lock.withLock { try? self.model.prediction(from: provider) }
        guard let embedding = output?.featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }
        var vector = [Float](repeating: 0, count: embedding.count)
        for index in 0..<embedding.count {
            vector[index] = embedding[index].floatValue
        }
        return vector
    }

    /// 内積（どちらも単位長なのでコサイン類似度）
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) {
            sum += a[index] * b[index]
        }
        return sum
    }
}

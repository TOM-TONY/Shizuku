#if ZenzaiANE
// llama.cpp の代わりに Core ML で zenz を動かす ZenzContext 実装。
//
// モデルは llm-ime の zenz/ane_gpt2.py で書き出した ANE 向け GPT-2:
//   - 入力 `input_ids` (1, S) int32、出力 `logits` (1, V, 1, S) fp16
//   - 系列長ごとの関数 `s128`, `s256` ... を持つマルチファンクションモデル（単一関数でも可）
//   - KV キャッシュは持たず、毎回全位置を計算する。後ろは PAD で埋める（因果マスクで影響しない）
// llama.cpp 版と同じく、logits は `startOffset` 以降の位置だけを行として返す。
import CoreML
import EfficientNGram
import Foundation
import SwiftUtils

/// 読み取り専用の Core ML モデルを複数の推論コンテキスト間で共有する。
private final class SharedZenzModel {
    struct Function {
        let seqLen: Int
        let model: MLModel
        let input: MLMultiArray
    }

    static let padToken: Int32 = 1

    let functions: [Function]  // seqLen 昇順
    let vocabSize: Int
    let tokenizer: ZenzTokenizer
    /// token id -> UTF-8 バイト列（llama_token_to_piece 相当。特殊トークンは空）
    let tokenBytes: [[CChar]]

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let config = MLModelConfiguration()
        config.computeUnits = Self.computeUnits
        var functions: [Function] = []
        if #available(macOS 15, iOS 18, *) {
            for seqLen in [64, 128, 256, 512] {
                config.functionName = "s\(seqLen)"
                if let model = try? MLModel(contentsOf: url, configuration: config) {
                    functions.append(try Self.makeFunction(model))
                }
            }
            config.functionName = nil
        }
        if functions.isEmpty {
            guard let model = try? MLModel(contentsOf: url, configuration: config) else {
                throw ZenzError.couldNotLoadModel(path: path)
            }
            functions.append(try Self.makeFunction(model))
        }
        self.functions = functions.sorted { $0.seqLen < $1.seqLen }
        guard let shape = functions[0].model.modelDescription
                .outputDescriptionsByName["logits"]?.multiArrayConstraint?.shape else {
            throw ZenzError.couldNotLoadModel(path: path)
        }
        self.vocabSize = shape[1].intValue
        self.tokenizer = ZenzTokenizer()
        self.tokenBytes = try Self.loadTokenBytes(vocabSize: self.vocabSize)
        debug("ZenzaiANE: loaded \(url.lastPathComponent) seqLens=\(self.functions.map(\.seqLen)) units=\(config.computeUnits.rawValue)")
    }

    private static func makeFunction(_ model: MLModel) throws -> Function {
        guard let shape = model.modelDescription.inputDescriptionsByName["input_ids"]?
                .multiArrayConstraint?.shape else {
            throw ZenzError.couldNotLoadContext
        }
        let seqLen = shape[1].intValue
        let input = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        return Function(seqLen: seqLen, model: model, input: input)
    }

    /// 比較計測用。既定は CPU + Neural Engine。
    private static var computeUnits: MLComputeUnits {
        switch ProcessInfo.processInfo.environment["AZOOKEY_ZENZ_COMPUTE_UNITS"] {
        case "cpuAndGPU": .cpuAndGPU
        case "cpuOnly": .cpuOnly
        case "all": .all
        default: .cpuAndNeuralEngine
        }
    }

    /// GPT-2 の byte-level 表現（vocab.json のキー）を元のバイト列に戻す表を作る。
    private static func loadTokenBytes(vocabSize: Int) throws -> [[CChar]] {
        let vocabURL = URL(fileURLWithPath: ZenzTokenizer.resourceDirectoryPath).appendingPathComponent("vocab.json")
        guard let vocab = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabURL)) as? [String: Int] else {
            throw ZenzError.couldNotLoadVocab
        }
        // bytes_to_unicode の逆写像
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var codepoints = printable
        var n = 0
        for b in 0..<256 where !printable.contains(b) {
            printable.append(b)
            codepoints.append(256 + n)
            n += 1
        }
        var unicodeToByte: [UInt32: UInt8] = [:]
        for (b, c) in zip(printable, codepoints) {
            unicodeToByte[UInt32(c)] = UInt8(b)
        }
        var table = [[CChar]](repeating: [], count: vocabSize)
        for (piece, id) in vocab where id >= 0 && id < vocabSize {
            // [UNK] [PAD] <s> </s> は制御トークン。llama.cpp（special=false）と同様に空文字列とする
            if id <= 3 { continue }
            var bytes: [CChar] = []
            for scalar in piece.unicodeScalars {
                guard let b = unicodeToByte[scalar.value] else { bytes = []; break }
                bytes.append(CChar(bitPattern: b))
            }
            table[id] = bytes
        }
        return table
    }
}

/// 同時に強参照するモデルを 1 個に制限する、プロセス共通のモデルキャッシュ。
private final class SharedZenzModelCache: @unchecked Sendable {
    static let shared = SharedZenzModelCache()

    private init() {
        self.cache.countLimit = 1
    }

    func model(path: String) throws -> SharedZenzModel {
        try self.lock.withLock {
            let key = path as NSString
            if let cached = self.cache.object(forKey: key) {
                return cached
            }
            let model = try SharedZenzModel(path: path)
            self.cache.setObject(model, forKey: key)
            return model
        }
    }

    private let cache = NSCache<NSString, SharedZenzModel>()
    private let lock = NSLock()
}

final class ZenzContext {
    /// zenz の終端トークン `</s>`。モデルはこの id で出力を終える。
    static let eosTokenID: llama_token = 3

    private let sharedModel: SharedZenzModel
    private var prevPromptBySeq: [llama_seq_id: String] = [:]
    private let evalSeqId: llama_seq_id = 0
    private let inputPredictionSeqId: llama_seq_id = 1
    /// `getLogits` の戻り値の格納先。次の呼び出しまで有効（llama_get_logits と同じ寿命）。
    private let logitsBuffer: UnsafeMutablePointer<Float>
    private let logitsCapacity: Int

    private init(sharedModel: SharedZenzModel) {
        self.sharedModel = sharedModel
        self.logitsCapacity = (sharedModel.functions.last?.seqLen ?? 0) * sharedModel.vocabSize
        self.logitsBuffer = .allocate(capacity: max(1, self.logitsCapacity))
    }

    deinit {
        self.logitsBuffer.deallocate()
    }

    static func createContext(path: String) throws -> ZenzContext {
        ZenzContext(sharedModel: try SharedZenzModelCache.shared.model(path: path))
    }

    func resetContext() throws {
        self.prevPromptBySeq = [:]
    }

    /// llama.cpp 版との互換のために残す（テストから参照される）。Core ML 版では使わない。
    static func selectInferenceThreadCount(activeProcessorCount: Int, performanceCoreCount: Int?) -> Int {
        let activeProcessorCount = max(1, activeProcessorCount)
        if let performanceCoreCount, performanceCoreCount > 0, performanceCoreCount <= activeProcessorCount {
            return performanceCoreCount
        }
        let reserved = activeProcessorCount >= 8 ? 2 : (activeProcessorCount >= 4 ? 1 : 0)
        return max(1, min(8, activeProcessorCount - reserved))
    }

    private func getLogits(tokens: [llama_token], logits_start_index: Int = 0) -> UnsafeMutablePointer<Float>? {
        guard !tokens.isEmpty, logits_start_index >= 0, logits_start_index < tokens.count else {
            return nil
        }
        guard let function = self.sharedModel.functions.first(where: { $0.seqLen >= tokens.count }) else {
            debug("ZenzaiANE: tokens.count \(tokens.count) exceeds the longest function")
            return nil
        }
        // 語彙外の ID を渡すと Core ML 内部で Objective-C 例外になり、Swift から捕捉できずにプロセスが落ちる
        let vocabSize = Int32(self.sharedModel.vocabSize)
        if let bad = tokens.first(where: { $0 < 0 || $0 >= vocabSize }) {
            debug("ZenzaiANE: out-of-vocabulary token id \(bad) (count=\(tokens.count))")
            FileHandle.standardError.write("ZenzaiANE: out-of-vocabulary token id \(bad) in \(tokens)\n".data(using: .utf8)!)
            return nil
        }
        let S = function.seqLen
        let ids = function.input.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<S {
            ids[i] = i < tokens.count ? tokens[i] : SharedZenzModel.padToken
        }
        // 推論ごとに Core ML が出力バッファ（IOSurface）を確保する。誤り訂正の探索のように 1 回の呼び出しで
        // 何百回も推論すると、自動解放プールが空になるまで解放されず確保に失敗して C++ 例外で落ちるため、
        // 推論と読み出しを autoreleasepool で囲んで都度解放する。
        let ok: Bool = autoreleasepool {
            let output: any MLFeatureProvider
            do {
                let provider = try MLDictionaryFeatureProvider(dictionary: ["input_ids": function.input])
                output = try function.model.prediction(from: provider)
            } catch {
                debug("ZenzaiANE: prediction failed: \(error)")
                return false
            }
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
                  logits.dataType == .float16 else {
                return false
            }
            let V = self.sharedModel.vocabSize
            let vStride = logits.strides[1].intValue
            let sStride = logits.strides[3].intValue
            let src = logits.dataPointer.assumingMemoryBound(to: Float16.self)
            for (row, pos) in (logits_start_index..<tokens.count).enumerated() {
                let dst = self.logitsBuffer + row * V
                let base = src + pos * sStride
                for v in 0..<V {
                    dst[v] = Float(base[v * vStride])
                }
            }
            return true
        }
        guard ok else {
            return nil
        }
        return self.logitsBuffer
    }

    func previousEvaluationPrompt() -> String {
        self.prevPromptBySeq[evalSeqId] ?? ""
    }

    func setPreviousEvaluationPrompt(_ prompt: String) {
        self.prevPromptBySeq[evalSeqId] = prompt
    }

    func normalizeForModel(_ text: String) -> String {
        self.preprocessText(text: text)
    }

    func encodeEvaluationPrompt(
        _ prompt: String,
        memoizationCache: ZenzaiMemoizationCache
    ) -> [llama_token] {
        if let cached = memoizationCache.cachedEvaluationPromptTokens(for: prompt) {
            return cached
        }
        let tokens = self.encode(prompt, addBOS: true, addEOS: false)
        memoizationCache.cacheEvaluationPromptTokens(tokens, for: prompt)
        return tokens
    }

    func encode(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        self.tokenize(text: self.preprocessText(text: text), addEOS: addEOS)
    }

    func encodeRaw(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        self.tokenize(text: text, addEOS: addEOS)
    }

    func evaluationLogits(tokens: [llama_token], startOffset: Int) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset)
    }

    func inputPredictionLogits(tokens: [llama_token], startOffset: Int) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset)
    }

    var vocabSize: Int {
        self.sharedModel.vocabSize
    }

    var eosToken: llama_token {
        Self.eosTokenID
    }

    func decodeTokens(_ tokens: [llama_token]) -> String {
        let cchars: [CChar] = tokens.flatMap(self.tokenToPiece)
        let data = Data(cchars.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// - note: The result does not contain null-terminator
    func tokenToPiece(token: llama_token) -> [CChar] {
        let id = Int(token)
        guard id >= 0 && id < self.sharedModel.tokenBytes.count else {
            return []
        }
        return self.sharedModel.tokenBytes[id]
    }

    private func preprocessText(text: String) -> String {
        // replace space into ideographic space (　) for zenz tokenizer
        // replace newline into null for zenz tokenizer
        text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
    }

    /// GGUF の add_bos_token は false のため、llama.cpp 版でも BOS は付与されない。それに合わせる。
    private func tokenize(text: String, addEOS: Bool) -> [llama_token] {
        var tokens = self.sharedModel.tokenizer.encode(text: text).map { llama_token($0) }
        if addEOS {
            tokens.append(Self.eosTokenID)
        }
        return tokens
    }
}
#endif

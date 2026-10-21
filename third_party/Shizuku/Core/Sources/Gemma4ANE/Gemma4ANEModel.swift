import Accelerate
import CoreML
import Foundation

/// llm-ime: Apple Neural Engine 上の Gemma 4（E2B/E4B）テキストモデル。
///
/// gemma4/convert_gemma4.py と gemma4/export_host.py が書き出したディレクトリを読む。
/// - ffn_c{k}.mlmodelc: 層の範囲ごとのチャンク（関数 infer: 1 トークン, prefill: PREFILL トークン）。
///   先頭チャンクが KV キャッシュを状態（MLState）として持ち、後のチャンクが使う KV を出力する
/// - lm_head.mlmodelc: 出力層（分割）＋ソフトキャップ
/// - embed.f16 / ple.f16: 埋め込みと層ごとの追加埋め込みの表（mmap して使う行だけ読む）
/// - tokenizer.bin, host.json, meta.json
///
/// スレッド安全ではない。1 つのキュー（actor）からだけ使うこと。
@available(macOS 15.0, *)
public final class Gemma4ANEModel: @unchecked Sendable {
    struct Meta: Decodable {
        struct Chunk: Decodable {
            var file: String
            var inputs: [String]
            var imports: [Int]
            var exports: [Int]
            var states: [String]
        }
        var ctx: Int
        var prefill: Int
        var lm_split: Int
        var chunks: [Chunk]
    }

    struct Host: Decodable {
        struct Rope: Decodable {
            var theta: Double
            var rotated: Int
        }
        var vocab: Int
        var hidden: Int
        var layers: Int
        var ple: Int
        var head_dim_sliding: Int
        var head_dim_full: Int
        var rope_sliding: Rope
        var rope_full: Rope
    }

    public enum ModelError: Error {
        case missingOutput(String)
        case tooLong(Int)
    }

    public let tokenizer: Gemma4Tokenizer
    /// KV キャッシュの長さ（扱える最大トークン数）
    public let contextLength: Int
    /// prefill 関数が一度に処理するトークン数
    public let prefillLength: Int
    public var vocabularySize: Int { self.host.vocab }

    private let meta: Meta
    private let host: Host
    private let embed: Data
    private let ple: Data
    private struct ChunkModels {
        var meta: Meta.Chunk
        var infer: MLModel
        var prefill: MLModel
    }
    private let chunks: [ChunkModels]
    private let head: MLModel
    /// 状態（KV キャッシュ）を持つチャンクごとの MLState。持たないチャンクは nil
    private var states: [MLState?]
    /// 位置ごとの RoPE（fp16, [位置][次元/2]）
    private let cosSliding: [Float16], sinSliding: [Float16], cosFull: [Float16], sinFull: [Float16]
    private var logitsBuffer: [Float]

    public init(directoryURL: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let decoder = JSONDecoder()
        self.meta = try decoder.decode(Meta.self, from: Data(contentsOf: directoryURL.appendingPathComponent("meta.json")))
        self.host = try decoder.decode(Host.self, from: Data(contentsOf: directoryURL.appendingPathComponent("host.json")))
        self.tokenizer = try Gemma4Tokenizer(url: directoryURL.appendingPathComponent("tokenizer.bin"))
        self.embed = try Data(contentsOf: directoryURL.appendingPathComponent("embed.f16"), options: .alwaysMapped)
        self.ple = try Data(contentsOf: directoryURL.appendingPathComponent("ple.f16"), options: .alwaysMapped)
        self.contextLength = self.meta.ctx
        self.prefillLength = self.meta.prefill
        func load(_ name: String, function: String?) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            configuration.functionName = function
            return try MLModel(contentsOf: directoryURL.appendingPathComponent("\(name).mlmodelc"), configuration: configuration)
        }
        self.chunks = try self.meta.chunks.map {
            ChunkModels(meta: $0, infer: try load($0.file, function: "infer"), prefill: try load($0.file, function: "prefill"))
        }
        self.head = try load("lm_head", function: nil)
        self.states = self.chunks.map { $0.meta.states.isEmpty ? nil : $0.infer.makeState() }
        func rope(headDim: Int, rotated: Int, theta: Double, ctx: Int) -> ([Float16], [Float16]) {
            let half = headDim / 2
            var cos = [Float16](repeating: 1, count: ctx * half)
            var sin = [Float16](repeating: 0, count: ctx * half)
            for j in 0..<rotated / 2 {
                let inv = pow(theta, -Double(2 * j) / Double(headDim))
                for p in 0..<ctx {
                    let angle = Double(p) * inv
                    cos[p * half + j] = Float16(Foundation.cos(angle))
                    sin[p * half + j] = Float16(Foundation.sin(angle))
                }
            }
            return (cos, sin)
        }
        (self.cosSliding, self.sinSliding) = rope(headDim: self.host.head_dim_sliding, rotated: self.host.rope_sliding.rotated, theta: self.host.rope_sliding.theta, ctx: self.meta.ctx)
        (self.cosFull, self.sinFull) = rope(headDim: self.host.head_dim_full, rotated: self.host.rope_full.rotated, theta: self.host.rope_full.theta, ctx: self.meta.ctx)
        self.logitsBuffer = [Float](repeating: 0, count: self.host.vocab)
    }

    /// KV キャッシュを空にする（以後は位置 0 から入力し直す）。
    public func resetState() {
        self.states = self.chunks.map { $0.meta.states.isEmpty ? nil : $0.infer.makeState() }
    }

    private static func array(_ shape: [Int], _ type: MLMultiArrayDataType = .float16) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    }

    private static func fill(_ array: MLMultiArray, _ body: (UnsafeMutablePointer<Float16>) -> Void) {
        array.withUnsafeMutableBytes { pointer, _ in
            body(pointer.baseAddress!.assumingMemoryBound(to: Float16.self))
        }
    }

    /// tokens を位置 start から入力し、最後のトークンの最終 hidden（C 次元）を返す。
    /// tokens.count == 1 なら infer、2 以上なら prefill（PREFILL 未満は末尾トークンで詰める）を使う。
    /// 呼び出し側は位置 start より前の KV が tokens の前の文脈で埋まっていることを保証すること。
    public func forward(tokens: [Int32], start: Int, isCancelled: () -> Bool = { false }) throws -> [Float16] {
        if isCancelled() { throw CancellationError() }
        let useInfer = tokens.count == 1
        let T = useInfer ? 1 : self.prefillLength
        precondition(!tokens.isEmpty && tokens.count <= T)
        guard start + T <= self.contextLength else {
            throw ModelError.tooLong(start + T)
        }
        let C = self.host.hidden, LP = self.host.layers * self.host.ple
        let hs = self.host.head_dim_sliding / 2, hf = self.host.head_dim_full / 2
        let ctx = self.contextLength
        let padded = tokens + Array(repeating: tokens.last!, count: T - tokens.count)
        return try autoreleasepool {
            let hidden = try Self.array([1, T, C])
            let pleRows = try Self.array([1, T, LP])
            self.embed.withUnsafeBytes { raw in
                let table = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                Self.fill(hidden) { dst in
                    for (t, id) in padded.enumerated() {
                        (dst + t * C).update(from: table + Int(id) * C, count: C)
                    }
                }
            }
            self.ple.withUnsafeBytes { raw in
                let table = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                Self.fill(pleRows) { dst in
                    for (t, id) in padded.enumerated() {
                        (dst + t * LP).update(from: table + Int(id) * LP, count: LP)
                    }
                }
            }
            func ropeArray(_ table: [Float16], half: Int) throws -> MLMultiArray {
                let a = try Self.array([1, 1, T, half])
                table.withUnsafeBufferPointer { src in
                    Self.fill(a) { dst in
                        (dst).update(from: src.baseAddress! + start * half, count: T * half)
                    }
                }
                return a
            }
            let mask = try Self.array([1, 1, T, ctx])
            Self.fill(mask) { dst in
                for t in 0..<T {
                    for p in 0..<ctx {
                        dst[t * ctx + p] = p <= start + t ? 0 : -Float16.infinity
                    }
                }
            }
            let position = try Self.array([1], .int32)
            position[0] = NSNumber(value: Int32(start))
            // チャンクの入力名 → 値。チャンクの出力（hidden, ple, kv_out_*）で順に更新する
            var pool: [String: MLFeatureValue] = [
                "hidden": MLFeatureValue(multiArray: hidden),
                "ple_rows": MLFeatureValue(multiArray: pleRows),
                "cos_s": MLFeatureValue(multiArray: try ropeArray(self.cosSliding, half: hs)),
                "sin_s": MLFeatureValue(multiArray: try ropeArray(self.sinSliding, half: hs)),
                "cos_f": MLFeatureValue(multiArray: try ropeArray(self.cosFull, half: hf)),
                "sin_f": MLFeatureValue(multiArray: try ropeArray(self.sinFull, half: hf)),
                "causal_mask": MLFeatureValue(multiArray: mask),
                "current_pos": MLFeatureValue(multiArray: position),
            ]
            try Gemma4ChunkExecution.run(zip(self.chunks, self.states), isCancelled: isCancelled) { chunk, state in
                var inputs: [String: MLFeatureValue] = [:]
                for name in chunk.meta.inputs {
                    guard let v = pool[name] else {
                        throw ModelError.missingOutput("\(name) for \(chunk.meta.file)")
                    }
                    inputs[name] = v
                }
                let model = useInfer ? chunk.infer : chunk.prefill
                let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
                let out = try state.map { try model.prediction(from: provider, using: $0) } ?? model.prediction(from: provider)
                guard let next = out.featureValue(for: "output_hidden") else {
                    throw ModelError.missingOutput(chunk.meta.file)
                }
                pool["hidden"] = next
                if let ple = out.featureValue(for: "ple") {
                    pool["ple"] = ple
                }
                for s in chunk.meta.exports {
                    guard let v = out.featureValue(for: "kv_out_\(s)") else {
                        throw ModelError.missingOutput("kv_out_\(s)")
                    }
                    pool["kv_in_\(s)"] = v
                }
            }
            guard let h = pool["hidden"]?.multiArrayValue else {
                throw ModelError.missingOutput("hidden")
            }
            // 実トークンの最後の行（strides を尊重して読む）
            let row = tokens.count - 1
            var result = [Float16](repeating: 0, count: C)
            h.withUnsafeBytes { raw in
                let strides = h.strides.map(\.intValue)
                let base = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                for c in 0..<C {
                    result[c] = base[row * strides[1] + c * strides[2]]
                }
            }
            return result
        }
    }

    public struct Prediction: Sendable {
        public var token: Int32
        public var logProb: Float
    }

    /// 最終 hidden から次トークンの分布を計算し、上位 k 件（対数確率つき）を返す。
    public func topTokens(hidden: [Float16], k: Int = 1) throws -> [Prediction] {
        let C = self.host.hidden
        let input = try Self.array([1, 1, C])
        hidden.withUnsafeBufferPointer { src in
            Self.fill(input) { $0.update(from: src.baseAddress!, count: C) }
        }
        return try autoreleasepool {
            let out = try self.head.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["hidden": MLFeatureValue(multiArray: input)]))
            let split = self.host.vocab / self.meta.lm_split
            try self.logitsBuffer.withUnsafeMutableBufferPointer { dst in
                for j in 0..<self.meta.lm_split {
                    guard let a = out.featureValue(for: "logits\(j)")?.multiArrayValue else {
                        throw ModelError.missingOutput("logits\(j)")
                    }
                    a.withUnsafeBytes { raw in
                        var srcBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1, width: vImagePixelCount(split), rowBytes: split * 2)
                        var dstBuffer = vImage_Buffer(data: dst.baseAddress! + j * split, height: 1, width: vImagePixelCount(split), rowBytes: split * 4)
                        vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, 0)
                    }
                }
            }
            return self.logitsBuffer.withUnsafeMutableBufferPointer { buf in
                let n = vDSP_Length(buf.count)
                var maxValue: Float = 0
                var maxIndex: vDSP_Length = 0
                vDSP_maxvi(buf.baseAddress!, 1, &maxValue, &maxIndex, n)
                // log Σ exp(x - max)
                var top: [(Int, Float)] = [(Int(maxIndex), maxValue)]
                if k > 1 {
                    // 最大値から離れすぎた語（確率比 e^-12 未満）は候補にしない。残りを並べて上位 k 件
                    let floor = maxValue - 12
                    var near: [(Int, Float)] = []
                    for i in 0..<buf.count where buf[i] >= floor {
                        near.append((i, buf[i]))
                    }
                    near.sort { $0.1 > $1.1 }
                    top = Array(near.prefix(k))
                }
                var negMax = -maxValue
                vDSP_vsadd(buf.baseAddress!, 1, &negMax, buf.baseAddress!, 1, n)
                var count = Int32(buf.count)
                vvexpf(buf.baseAddress!, buf.baseAddress!, &count)
                var sum: Float = 0
                vDSP_sve(buf.baseAddress!, 1, &sum, n)
                let logZ = maxValue + log(sum)
                return top.map { Prediction(token: Int32($0.0), logProb: $0.1 - logZ) }
            }
        }
    }
}

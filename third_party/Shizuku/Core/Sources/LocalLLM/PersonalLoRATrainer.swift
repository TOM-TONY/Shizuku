import Foundation
import Gemma4ANE
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers

/// 本人が選んだ答えだけを学習する。ベース重みは凍結し、短い系列を一件ずつ処理する。
public enum PersonalLoRATrainer {
    public enum TrainingError: LocalizedError {
        case insufficientSamples(Int, Int)
        public var errorDescription: String? {
            switch self {
            case .insufficientSamples(let available, let required): "系列長256以内の学習の組が \(available) 件（必要 \(required) 件）"
            }
        }
    }
    public struct Example: Sendable {
        public var system: String
        public var user: String
        public var answer: String
        public init(system: String, user: String, answer: String) {
            self.system = system; self.user = user; self.answer = answer
        }
    }
    public struct Result: Sendable {
        public var samples: Int
        public var finalLoss: Double
        public var trainableParameters: Int
    }
    public static func train(modelDirectory: URL, output: URL, examples: [Example], iterations: Int = 48,
                             seed: UInt64, minimumSamples: Int = 2000,
                             progress: @escaping @Sendable (Int, Double) -> Void) async throws -> Result {
        guard (1...96).contains(iterations), (1...2000).contains(minimumSamples), !examples.isEmpty else { throw LocalLLMEngine.EngineError.noAnswer }
        await LocalLLMEngine.shared.unload()
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        let container = try await LLMModelFactory.shared.loadContainer(from: modelDirectory,
            using: LocalLLMEngine.tokenizerLoader(for: modelDirectory))
        let activity = InferenceActivity.ticket(), began = DispatchTime.now().uptimeNanoseconds
        defer { InferenceActivity.report(feature: "lora", device: "GPU", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000, ticket: activity) }
        let result = try await container.perform { context in
            guard let model = context.model as? any LLMModel, let lora = model as? any LoRAModel else {
                throw ModelAdapterError.incompatibleModelType
            }
            let keys = lora.loraDefaultKeys.filter { $0.hasSuffix("q_proj") || $0.hasSuffix("v_proj") }.sorted()
            guard !keys.isEmpty else { throw ModelAdapterError.incompatibleModelType }
            let configuration = LoRAConfiguration(numLayers: 4, loraParameters: .init(rank: 8, scale: 10, dropout: 0, keys: keys))
            MLXRandom.seed(seed)
            var batches: [(tokens: [Int], start: Int)] = []
            for example in examples {
                let prompt = try context.tokenizer.applyChatTemplate(messages: [
                    ["role": "system", "content": example.system], ["role": "user", "content": example.user]
                ], tools: nil, additionalContext: ["enable_thinking": false])
                let answer = context.tokenizer.encode(text: example.answer, addSpecialTokens: false)
                let tokens = prompt + answer + (context.tokenizer.eosTokenId.map { [$0] } ?? [])
                // 答えを切り捨てて学習しない。長すぎる記録は飛ばす。
                if !answer.isEmpty, !prompt.isEmpty, tokens.count <= 256 {
                    batches.append((tokens, prompt.count - 1))
                }
            }
            guard batches.count >= minimumSamples else { throw TrainingError.insufficientSamples(batches.count, minimumSamples) }
            _ = try LoRAContainer.from(model: model, configuration: configuration)
            let parameterCount = model.trainableParameters().flattened().reduce(0) { $0 + $1.1.size }
            guard parameterCount > 0 else { throw ModelAdapterError.incompatibleModelType }
            model.train(true)
            defer { model.train(false) }
            let optimizer = Adam(learningRate: 1e-5)
            let module: Module = model
            let gradient = valueAndGrad(model: module) { module, arrays in
                let logits = (module as! any LLMModel)(arrays[0], cache: nil).asType(.float32)
                let loss = (crossEntropy(logits: logits, targets: arrays[1]) * arrays[2]).sum() / arrays[2].sum()
                return [loss]
            }
            var rng = seed
            var loss = 0.0
            for step in 0..<iterations {
                try Task.checkCancellation()
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let batch = batches[Int(rng % UInt64(batches.count))]
                let length = batch.tokens.count - 1
                let x = MLXArray(Array(batch.tokens.dropLast())).reshaped([1, length])
                let y = MLXArray(Array(batch.tokens.dropFirst())).reshaped([1, length])
                let mask = MLXArray((0..<length).map { Float($0 >= batch.start ? 1 : 0) }).reshaped([1, length])
                let (values, grads) = gradient(module, [x, y, mask])
                optimizer.update(model: model, gradients: grads)
                eval(model, optimizer, values[0])
                loss = Double(values[0].item(Float.self))
                guard loss.isFinite, loss >= 0 else { throw LocalLLMEngine.EngineError.noAnswer }
                progress(step + 1, loss)
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: output.appendingPathComponent("adapter_config.json"), options: .atomic)
            try LoRATrain.saveLoRAWeights(model: model, url: output.appendingPathComponent("adapters.safetensors"))
            return Result(samples: batches.count, finalLoss: loss, trainableParameters: parameterCount)
        }
        MLX.GPU.clearCache()
        return result
    }
}

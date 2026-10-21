import Foundation
import Gemma4ANE
import MLX
import MLXLLM
import MLXLMCommon

/// llm-ime: いい感じ変換・添削・書き直し用のローカル LLM（Gemma 4 12B / 31B を MLX で GPU 実行）。
///
/// 重みは Application Support のモデルのディレクトリから読み、実行時に通信はしない。メモリを
/// 12B で約 11GB、31B で約 22GB 使うため、使うときに読み込み、しばらく使われなければ解放する。
public actor LocalLLMEngine {
    public static let shared = LocalLLMEngine()

    public static let standardModelName = "gemma4-12b-it-mlx"
    public static let largeModelName = "gemma4-31b-it-mlx"

    /// ConverterServer はサンドボックス外で動くため、ホームの Application Support を読める
    public static func modelDirectoryURL(name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/llm-ime/models", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func isModelInstalled(at directory: URL) -> Bool {
        let fm = FileManager.default
        func exists(_ file: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(file).path)
        }
        return exists("config.json") && (exists("tokenizer.bin") || exists("tokenizer.json"))
    }

    /// Gemma 4（tokenizer.bin を書き出したもの）は自前のトークナイザ（チャットテンプレートを確認済み）、
    /// それ以外は tokenizer.json とチャットテンプレート（Jinja）を読む汎用のトークナイザ
    static func tokenizerLoader(for directory: URL) -> any MLXLMCommon.TokenizerLoader {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.bin").path) {
            return Gemma4ChatTokenizerLoader()
        }
        return HFChatTokenizerLoader()
    }

    public enum EngineError: LocalizedError {
        case modelNotInstalled(String)
        case loadFailed(String, String)
        case noAnswer

        public var errorDescription: String? {
            switch self {
            case .modelNotInstalled(let path):
                "ローカル LLM のモデルが見つかりません: \(path)"
            case .loadFailed(let name, let reason):
                "モデル「\(name)」を読み込めませんでした（\(reason)）。設定の「いい感じ変換のモデル」で別のモデルを選んでください"
            case .noAnswer:
                "答えが得られませんでした（考えてから答える設定では、考えるのに時間がかかりすぎた可能性があります）"
            }
        }
    }

    private static let idleUnloadInterval: Duration = .seconds(300)

    private var container: ModelContainer?
    private var loadedDirectory: URL?
    private var loadedAdapter: URL?
    private var privacyGeneration = 0
    private var activeRequests = 0
    public var isBusy: Bool { self.activeRequests > 0 }
    private var unloadTask: Task<Void, Never>?

    private init() {}

    private func loadedContainer(directory: URL, adapter: URL? = nil) async throws -> ModelContainer {
        if let container, self.loadedDirectory == directory, self.loadedAdapter == adapter {
            return container
        }
        // 別のモデルに切り替えるときは先に解放する（両方を同時にメモリに置かない）
        self.unload()
        guard Self.isModelInstalled(at: directory) else {
            throw EngineError.modelNotInstalled(directory.path)
        }
        // 生成のたびに増える一時バッファを抱え込まないよう、MLX のキャッシュ上限を抑える
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
        // 文章だけを扱う（画像・音声の部分は読み込まない）。gemma4 / gemma4_unified の両方に対応
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: Self.tokenizerLoader(for: directory)
            )
        } catch {
            throw EngineError.loadFailed(directory.lastPathComponent, error.localizedDescription)
        }
        if let adapter {
            try await container.perform { context in
                let data = try Data(contentsOf: adapter.appendingPathComponent("adapter_config.json"))
                guard data.count <= 16384 else { throw EngineError.noAnswer }
                let c = try JSONDecoder().decode(LoRAConfiguration.self, from: data)
                guard (2...16).contains(c.loraParameters.rank), (1...8).contains(c.numLayers),
                      c.fineTuneType == .lora, c.loraParameters.dropout == 0,
                      c.loraParameters.scale == 10,
                      let keys = c.loraParameters.keys, !keys.isEmpty,
                      keys.allSatisfy({ $0.hasSuffix("q_proj") || $0.hasSuffix("v_proj") }) else {
                    throw EngineError.noAnswer
                }
                let weights = try LoRAContainer.from(directory: adapter)
                try weights.load(into: context.model)
                eval(context.model)
            }
        }
        self.container = container
        self.loadedDirectory = directory
        self.loadedAdapter = adapter
        return container
    }

    private func scheduleUnload() {
        self.unloadTask?.cancel()
        self.unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadInterval)
            guard !Task.isCancelled else {
                return
            }
            await self?.unload()
        }
    }

    /// モデルを解放する（次の要求で読み直す）。
    public func unload() {
        self.container = nil
        self.loadedDirectory = nil
        self.loadedAdapter = nil
        MLX.GPU.clearCache()
    }

    /// 記録の削除・個人化オフ・版の切替で、待っている返答も採用させない。
    public func invalidatePersonalization() {
        self.privacyGeneration += 1
        self.unload()
    }

    /// モデルを先に読み込んでおく。
    public func preload(directory: URL) async {
        _ = try? await self.loadedContainer(directory: directory)
        self.scheduleUnload()
    }

    /// 1 回のやり取りで答えを得る（会話履歴は持たない）。thinking なら考えてから答える（遅いが正確になりうる）。
    public func respond(
        system: String?,
        user: String,
        modelDirectory: URL,
        maxTokens: Int = 256,
        temperature: Float = 0,
        thinking: Bool = false,
        adapterDirectory: URL? = nil,
        usageFeature: String = "local-llm"
    ) async throws -> String {
        self.activeRequests += 1
        defer { self.activeRequests -= 1 }
        let generation = self.privacyGeneration
        let container = try await self.loadedContainer(directory: modelDirectory, adapter: adapterDirectory)
        defer {
            self.scheduleUnload()
        }
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: thinking ? maxTokens + 4096 : maxTokens, temperature: temperature),
            additionalContext: ["enable_thinking": thinking]
        )
        let activity = InferenceActivity.ticket(), began = DispatchTime.now().uptimeNanoseconds
        defer { InferenceActivity.report(feature: usageFeature, device: "GPU", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000, ticket: activity) }
        let text = try await session.respond(to: user)
        guard generation == self.privacyGeneration else { throw EngineError.noAnswer }
        // 思考の途中で生成の上限に達した（答えがない）場合や、答えが空の場合は失敗にする
        for (openMark, closeMark) in [("<|channel>", "<channel|>"), ("<think>", "</think>")] {
            if let open = text.range(of: openMark, options: .backwards), text.range(of: closeMark, range: open.upperBound..<text.endIndex) == nil {
                throw EngineError.noAnswer
            }
        }
        let answer = Self.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw EngineError.noAnswer
        }
        return answer
    }

    /// 評価用: 答えと、最初の文字が出るまでの時間・全体の時間（秒）。思考なし
    public func respondTimed(
        system: String?,
        user: String,
        modelDirectory: URL,
        maxTokens: Int = 256,
        adapterDirectory: URL? = nil
    ) async throws -> (text: String, firstChunk: Double, total: Double) {
        self.activeRequests += 1
        defer { self.activeRequests -= 1 }
        let container = try await self.loadedContainer(directory: modelDirectory, adapter: adapterDirectory)
        defer {
            self.scheduleUnload()
        }
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
            additionalContext: ["enable_thinking": false]
        )
        let start = Date()
        var firstChunk: Double?
        var text = ""
        for try await chunk in session.streamResponse(to: user) {
            if firstChunk == nil, !chunk.isEmpty {
                firstChunk = Date().timeIntervalSince(start)
            }
            text += chunk
        }
        let total = Date().timeIntervalSince(start)
        return (Self.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines), firstChunk ?? total, total)
    }

    /// 念のため、思考の部分が出力に残っていたら除く（Gemma 4 の <|channel>…<channel|>、Qwen などの <think>…</think>）。
    static func stripThinking(_ text: String) -> String {
        var text = text
        for (open, close) in [("<|channel>", "<channel|>"), ("<think>", "</think>")] {
            var result = ""
            for part in text.components(separatedBy: close) {
                if let range = part.range(of: open) {
                    result += part[..<range.lowerBound]
                } else {
                    result += part
                }
            }
            text = result
        }
        return text
    }
}

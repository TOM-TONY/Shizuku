import Foundation

/// llm-ime: ~/Library/Application Support/llm-ime/models に入っているモデルの一覧。
///
/// - 続き予測（ANE）: gemma4/convert_gemma4.py で変換した形式（meta.json・host.json・tokenizer.bin・*.mlmodelc）
/// - いい感じ変換（MLX・GPU）: Hugging Face の MLX 形式（config.json・*.safetensors と、tokenizer.json か tokenizer.bin）。
///   mlx-swift-lm が対応する model_type のものだけを使える
/// - 文の埋め込み（Core ML、解析と学習 段階 B）: tools/embedding/package_embedder.sh で作る形式（embedding.json・tokenizer.json・
///   embedder.mlmodelc）。手本選びに意味の近さを足すとき（解析で採用したときだけ）に使う
///
/// フォルダを置くだけで選べるようにする。中身を読まずに、ファイルの有無と設定ファイルだけで判断する（大きな重みは読まない）。
/// ConverterServer（サンドボックス外）で使う。IME 本体からはこのフォルダを読めない。
public enum ModelCatalog {
    public enum Kind: String, Sendable, Codable {
        /// 続き予測（ANE）
        case completion
        /// いい感じ変換・添削・書き直し（MLX・GPU）
        case chat
        /// 文の埋め込み（Core ML）
        case embedding
    }

    /// 文の埋め込みのモデルの説明（embedding.json）
    public struct EmbeddingInfo: Sendable, Equatable, Codable {
        /// 入力の長さ（トークン、固定）
        public var length: Int
        /// ベクトルの次元
        public var dimension: Int
        /// 文の前に付ける言葉（ruri-v3 は "検索クエリ: " / "検索文書: "。付けるかは評価で決めて書く）
        public var queryPrefix: String
        public var documentPrefix: String
        /// 元のモデル（リポジトリ@コミット）とライセンス
        public var source: String
        public var license: String

        public init(length: Int, dimension: Int, queryPrefix: String, documentPrefix: String, source: String, license: String) {
            self.length = length
            self.dimension = dimension
            self.queryPrefix = queryPrefix
            self.documentPrefix = documentPrefix
            self.source = source
            self.license = license
        }
    }

    public static func embeddingInfo(at url: URL) -> EmbeddingInfo? {
        (try? Data(contentsOf: url.appendingPathComponent("embedding.json"))).flatMap { try? JSONDecoder().decode(EmbeddingInfo.self, from: $0) }
    }

    public struct Model: Sendable, Equatable, Codable {
        /// フォルダ名（設定に保存する値）
        public var name: String
        public var kind: Kind
        /// 表示名（例: Gemma 4 31B）
        public var displayName: String
        /// 補足（例: 4bit・22 GB）
        public var detail: String
        public var bytes: Int64
        /// 使えない理由（nil なら使える）
        public var problem: String?
        /// 動かすのに足りないかもしれないときの注意
        public var warning: String?

        public var isUsable: Bool {
            self.problem == nil
        }

        /// 選択肢に出す文字列
        public var title: String {
            var text = "\(self.displayName)（\(self.detail)）"
            if let warning {
                text += " — \(warning)"
            }
            return text
        }
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/llm-ime/models", isDirectory: true)
    }

    /// mlx-swift-lm 3.32.3 の LLMTypeRegistry が対応する model_type（入れ子の text_config.model_type も見る）
    public static let supportedChatModelTypes: Set<String> = [
        "mistral", "mixtral", "llama", "phi", "phi3", "phimoe", "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
        "gemma4", "gemma4_unified", "gemma4_text", "qwen2", "qwen3", "qwen3_moe", "qwen3_next", "qwen3_5", "qwen3_5_moe",
        "qwen3_5_text", "nanbeige", "minicpm", "starcoder2", "cohere", "openelm", "internlm2", "deepseek_v2", "deepseek_v3",
        "granite", "helium", "granitemoehybrid", "mimo", "mimo_v2_flash", "minimax", "glm4", "glm4_moe", "glm4_moe_lite",
        "acereason", "falcon_h1", "bitnet", "smollm3", "ernie4_5", "lfm2", "baichuan_m1", "exaone4", "gpt_oss", "olmoe",
        "olmo2", "olmo3", "bailing_moe", "lfm2_moe", "nanochat", "nemotron_h", "afmoe", "jamba", "mamba2", "mistral3",
        "apertus", "hunyuan_v1_dense",
    ]

    /// 同梱・既定のモデルの表示名
    private static let knownNames: [String: String] = [
        "gemma4-e4b-ane": "Gemma 4 E4B",
        "gemma4-e2b-ane": "Gemma 4 E2B",
        "gemma4-12b-it-mlx": "Gemma 4 12B",
        "gemma4-31b-it-mlx": "Gemma 4 31B",
        "ruri-v3-30m-coreml": "Ruri v3 30M（文の埋め込み）",
    ]

    /// 文の埋め込みの既定のモデル（フォルダ名）
    public static let defaultEmbeddingModel = "ruri-v3-30m-coreml"

    /// フォルダの中のモデルを、種類ごとに名前順で返す
    public static func models(kind: Kind? = nil, in directory: URL = Self.directory) -> [Model] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let memory = Int64(ProcessInfo.processInfo.physicalMemory)
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { Self.inspect($0, memory: memory) }
            .filter { kind == nil || $0.kind == kind }
            .sorted { ($0.kind.rawValue, $0.displayName, $0.name) < ($1.kind.rawValue, $1.displayName, $1.name) }
    }

    public static func model(named name: String, kind: Kind, in directory: URL = Self.directory) -> Model? {
        guard !name.isEmpty, !name.contains("/") else {
            return nil
        }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        return Self.inspect(url, memory: Int64(ProcessInfo.processInfo.physicalMemory)).flatMap { $0.kind == kind ? $0 : nil }
    }

    /// 選んだモデルが使えればその場所、使えなければ fallbacks の順に、それもなければ使えるものの先頭
    public static func resolve(selected: String, kind: Kind, fallbacks: [String], in directory: URL = Self.directory) -> URL? {
        for name in [selected] + fallbacks {
            if let model = Self.model(named: name, kind: kind, in: directory), model.isUsable {
                return directory.appendingPathComponent(model.name, isDirectory: true)
            }
        }
        return Self.models(kind: kind, in: directory).first(where: \.isUsable).map { directory.appendingPathComponent($0.name, isDirectory: true) }
    }

    static func inspect(_ url: URL, memory: Int64) -> Model? {
        let fm = FileManager.default
        func exists(_ file: String) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent(file).path)
        }
        let name = url.lastPathComponent
        // 文の埋め込み（Core ML）
        if exists("embedding.json") {
            let bytes = Self.size(of: url)
            var problem: String?
            if Self.embeddingInfo(at: url) == nil {
                problem = "embedding.json を読めません"
            } else if !exists("tokenizer.json") || !exists("embedder.mlmodelc") {
                problem = "ファイルが足りません（tokenizer.json・embedder.mlmodelc）"
            }
            return Model(
                name: name, kind: .embedding, displayName: Self.knownNames[name] ?? Self.readableName(name),
                detail: "Neural Engine・\(Self.format(bytes))", bytes: bytes, problem: problem, warning: nil
            )
        }
        // 続き予測（ANE）
        if exists("meta.json") && exists("host.json") {
            let bytes = Self.size(of: url)
            var problem: String?
            if !exists("tokenizer.bin") || !exists("lm_head.mlmodelc") {
                problem = "ファイルが足りません（tokenizer.bin・lm_head.mlmodelc）"
            }
            return Model(
                name: name, kind: .completion,
                displayName: Self.knownNames[name] ?? name,
                detail: "Neural Engine・\(Self.format(bytes))",
                bytes: bytes, problem: problem, warning: nil
            )
        }
        // いい感じ変換（MLX）
        guard exists("config.json"),
              let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        guard files.contains(where: { $0.hasSuffix(".safetensors") }) else {
            return nil
        }
        let modelType = config["model_type"] as? String ?? ""
        let textType = (config["text_config"] as? [String: Any])?["model_type"] as? String
        let quantization = (config["quantization"] as? [String: Any]) ?? (config["quantization_config"] as? [String: Any])
        let bits = quantization?["bits"] as? Int
        let bytes = Self.size(of: url, suffix: ".safetensors")
        var problem: String?
        if !Self.supportedChatModelTypes.contains(modelType) && !(textType.map(Self.supportedChatModelTypes.contains) ?? false) {
            problem = "対応していない形式です（\(modelType.isEmpty ? "model_type なし" : modelType)）"
        } else if !(exists("tokenizer.json") || (exists("tokenizer.bin") && modelType.hasPrefix("gemma4"))) {
            problem = "トークナイザ（tokenizer.json）がありません"
        } else if !exists("tokenizer.bin"), !exists("chat_template.jinja"), !Self.tokenizerConfigHasChatTemplate(url) {
            problem = "チャットテンプレートがありません（指示に答えるモデルではない可能性があります）"
        }
        // 重み＋作業用に 1.3 倍ほど要る
        let warning: String? = Double(bytes) * 1.3 > Double(memory) * 0.75 ? "この Mac ではメモリが足りない可能性があります" : nil
        return Model(
            name: name, kind: .chat,
            displayName: Self.knownNames[name] ?? Self.readableName(name),
            detail: [bits.map { "\($0)bit" }, "GPU", Self.format(bytes)].compactMap(\.self).joined(separator: "・"),
            bytes: bytes, problem: problem, warning: warning
        )
    }

    private static func tokenizerConfigHasChatTemplate(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("tokenizer_config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return config["chat_template"] != nil
    }

    /// フォルダ名からの表示名（IME 本体はフォルダを読めないので、設定に入っているフォルダ名から作る）
    public static func displayName(forDirectory name: String) -> String {
        Self.knownNames[name] ?? Self.readableName(name)
    }

    /// フォルダ名を読みやすくする（mlx-community の名前など: Qwen3-8B-4bit → Qwen3 8B 4bit）
    private static func readableName(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    private static func size(of url: URL, suffix: String? = nil) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let suffix, !file.lastPathComponent.hasSuffix(suffix) {
                continue
            }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private static func format(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }
}

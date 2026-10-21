import Foundation
import MLXLMCommon
import Tokenizers

/// llm-ime: Gemma 4 以外のローカル LLM（Qwen・Llama・Mistral・Gemma 3 など、Hugging Face の MLX 形式）のトークナイザ。
///
/// モデルのフォルダの tokenizer.json・tokenizer_config.json を swift-tokenizers で読み、チャットテンプレート（Jinja）で
/// 会話を組み立てる。テンプレートが tokenizer_config.json になく chat_template.jinja にあるモデル（新しい形式）にも対応する。
/// swift-tokenizers の Jinja は古く、新しいテンプレート（Gemma 4 など）を読めないことがあるので、そのときはモデルの種類
/// （config.json の model_type）ごとの標準の会話形式で組み立てる。フォルダの中だけを読み、通信はしない。
struct HFChatTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let base = try await AutoTokenizer.from(modelFolder: directory)
        let template = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        var modelType = ""
        if let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
           let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            modelType = config["model_type"] as? String ?? ""
        }
        return HFChatTokenizer(base: base, chatTemplate: template, modelType: modelType)
    }
}

struct HFChatTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let base: any Tokenizers.Tokenizer
    /// chat_template.jinja（tokenizer_config.json にテンプレートがないときに使う）
    let chatTemplate: String?
    /// config.json の model_type（テンプレートを読めないときの会話形式の判断に使う）
    let modelType: String

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        self.base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        self.base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        self.base.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        self.base.convertIdToToken(id)
    }

    var bosToken: String? { self.base.bosToken }
    var eosToken: String? {
        // 会話の終わりの印（生成を止める）。テンプレートの形式に合わせる
        switch self.format {
        case .chatML: "<|im_end|>"
        case .llama3: "<|eot_id|>"
        case .gemma: "<end_of_turn>"
        case .gemma4: "<turn|>"
        case .mistral: self.base.eosToken
        }
    }
    var unknownToken: String? { self.base.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let converted: [Tokenizers.Message] = messages.map { $0.mapValues { $0 as Any } }
        let context: [String: Any]? = additionalContext?.mapValues { $0 as Any }
        let template: ChatTemplateArgument? = self.base.hasChatTemplate ? nil : self.chatTemplate.map { .literal($0) }
        if self.base.hasChatTemplate || template != nil {
            do {
                return try self.base.applyChatTemplate(
                    messages: converted,
                    chatTemplate: template,
                    addGenerationPrompt: true,
                    truncation: false,
                    maxLength: nil,
                    tools: nil,
                    additionalContext: context
                )
            } catch {
                NSLog("llm-ime: chat template failed (%@), using the standard format for %@", String(describing: error), self.modelType)
            }
        }
        let thinking = additionalContext?["enable_thinking"] as? Bool ?? false
        let prompt = self.standardPrompt(messages: messages, thinking: thinking)
        return self.base.encode(text: prompt, addSpecialTokens: false)
    }

    // MARK: - テンプレートを読めないときの標準の会話形式

    enum Format {
        case chatML
        case llama3
        case gemma
        case gemma4
        case mistral
    }

    var format: Format {
        let type = self.modelType
        if type.hasPrefix("gemma4") {
            return .gemma4
        }
        if type.hasPrefix("gemma") {
            return .gemma
        }
        if type == "llama", self.base.convertTokenToId("<|eot_id|>") != nil {
            return .llama3
        }
        if type.hasPrefix("mistral") || type == "mixtral" {
            return .mistral
        }
        return .chatML
    }

    func standardPrompt(messages: [[String: any Sendable]], thinking: Bool) -> String {
        let turns = messages.map { (role: ($0["role"] as? String) ?? "user", content: ($0["content"] as? String) ?? "") }
        let system = turns.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        let others = turns.filter { $0.role != "system" }
        let bos = self.base.bosToken ?? ""
        switch self.format {
        case .chatML:
            var text = system.isEmpty ? "" : "<|im_start|>system\n\(system)<|im_end|>\n"
            for turn in others {
                text += "<|im_start|>\(turn.role)\n\(turn.content)<|im_end|>\n"
            }
            text += "<|im_start|>assistant\n"
            // Qwen3 系は、考えないときに空の思考を置く（テンプレートと同じ）
            if !thinking, self.modelType.hasPrefix("qwen3") {
                text += "<think>\n\n</think>\n\n"
            }
            return text
        case .llama3:
            var text = "<|begin_of_text|>"
            if !system.isEmpty {
                text += "<|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|>"
            }
            for turn in others {
                text += "<|start_header_id|>\(turn.role)<|end_header_id|>\n\n\(turn.content)<|eot_id|>"
            }
            return text + "<|start_header_id|>assistant<|end_header_id|>\n\n"
        case .gemma:
            // Gemma 1〜3 には system の役割がないので、最初の発言の前に置く
            var text = bos
            for (index, turn) in others.enumerated() {
                let role = turn.role == "assistant" ? "model" : "user"
                let content = index == 0 && !system.isEmpty ? system + "\n\n" + turn.content : turn.content
                text += "<start_of_turn>\(role)\n\(content)<end_of_turn>\n"
            }
            return text + "<start_of_turn>model\n"
        case .gemma4:
            var text = "<bos><|turn>system\n" + (thinking ? "<|think|>\n" : "") + system + "<turn|>\n"
            for turn in others {
                text += "<|turn>\(turn.role == "assistant" ? "model" : "user")\n\(turn.content)<turn|>\n"
            }
            return text + "<|turn>model\n" + (thinking ? "" : "<|channel>thought\n<channel|>")
        case .mistral:
            var text = bos
            for (index, turn) in others.enumerated() where turn.role == "user" {
                let content = index == 0 && !system.isEmpty ? system + "\n\n" + turn.content : turn.content
                text += "[INST] \(content) [/INST]"
            }
            return text
        }
    }
}

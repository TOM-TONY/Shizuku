import Foundation
import Gemma4ANE
import MLXLMCommon

/// llm-ime: Gemma 4 の Tokenizer（mlx-swift-lm 用）。
///
/// 語彙は E2B/E4B/12B で同一なので、続き予測と同じ `Gemma4Tokenizer`（tokenizer.bin）を使う。
/// チャットテンプレートは chat_template.jinja のうち使う部分（system / user / model、思考なし）だけを
/// Swift で組み立てる（HF の apply_chat_template と同じ文字列になることを確認済み）:
///   思考なし: <bos><|turn>system\n{system}<turn|>\n<|turn>user\n{user}<turn|>\n<|turn>model\n<|channel>thought\n<channel|>
///   思考あり: <bos><|turn>system\n<|think|>\n{system}<turn|>\n<|turn>user\n{user}<turn|>\n<|turn>model\n
///            （system がなければ空の system ターンを置く）
/// （swift-transformers は変換エンジンが使う別のトークナイザパッケージと名前が衝突するため使わない）
struct Gemma4ChatTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Gemma4ChatTokenizer(try Gemma4Tokenizer(url: directory.appendingPathComponent("tokenizer.bin")))
    }
}

struct Gemma4ChatTokenizer: MLXLMCommon.Tokenizer {
    private let base: Gemma4Tokenizer

    init(_ base: Gemma4Tokenizer) {
        self.base = base
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        (addSpecialTokens ? [Int(self.base.bos)] : []) + self.base.encode(text).map(Int.init)
    }

    /// 特殊トークンを除く場合も、思考チャネルの印（<|channel> / <channel|>）は残す（呼び出し側で思考を取り除くため）。
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        guard skipSpecialTokens else {
            return self.base.string(fromBytes: self.base.bytes(tokenIds.map { Int32($0) }, skipSpecialTokens: false))
        }
        let channelStart = self.special("<|channel>"), channelEnd = self.special("<channel|>")
        var bytes: [UInt8] = []
        var segment: [Int32] = []
        for id in tokenIds {
            if id == channelStart || id == channelEnd {
                bytes += self.base.bytes(segment) + Array((id == channelStart ? "<|channel>" : "<channel|>").utf8)
                segment = []
            } else {
                segment.append(Int32(id))
            }
        }
        bytes += self.base.bytes(segment)
        return self.base.string(fromBytes: bytes)
    }

    func convertTokenToId(_ token: String) -> Int? {
        self.base.tokenID(forPiece: token).map(Int.init)
    }

    func convertIdToToken(_ id: Int) -> String? {
        self.base.piece(for: Int32(id))
    }

    var bosToken: String? { "<bos>" }
    var eosToken: String? { "<turn|>" }
    var unknownToken: String? { "<unk>" }

    private func special(_ piece: String) -> Int {
        Int(self.base.tokenID(forPiece: piece) ?? 0)
    }

    /// メッセージの本文（文字列、または [{"type": "text", "text": ...}] の配列）を取り出す。
    private static func text(of content: Any?) -> String {
        if let s = content as? String {
            return s
        }
        if let parts = content as? [[String: any Sendable]] {
            return parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
        }
        if let parts = content as? [Any] {
            return parts.compactMap { ($0 as? [String: Any]).flatMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil } }.joined()
        }
        return ""
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let turnStart = self.special("<|turn>"), turnEnd = self.special("<turn|>")
        let newline = self.base.encode("\n").map(Int.init)
        let thinking = (additionalContext?["enable_thinking"] as? Bool) ?? false
        var ids = [Int(self.base.bos)]
        var messages = messages
        if thinking, (messages.first?["role"] as? String).map({ $0 == "system" || $0 == "developer" }) != true {
            messages.insert(["role": "system", "content": ""], at: 0)
        }
        for (index, message) in messages.enumerated() {
            var role = (message["role"] as? String) ?? "user"
            if role == "assistant" {
                role = "model"
            } else if role == "developer" {
                role = "system"
            }
            // HF と同じく、特殊トークンの間の文字列（役割名＋本文）をまとめてトークン化する
            let content = Self.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            ids.append(turnStart)
            if thinking, index == 0 {
                // 思考を使う指定（最初の system ターンの先頭）
                ids += self.base.encode(role + "\n").map(Int.init)
                ids.append(self.special("<|think|>"))
                ids += self.base.encode("\n" + content).map(Int.init)
            } else {
                ids += self.base.encode(role + "\n" + content).map(Int.init)
            }
            ids.append(turnEnd)
            ids += newline
        }
        ids.append(turnStart)
        ids += self.base.encode("model\n").map(Int.init)
        // 思考を使わない（chat_template.jinja で enable_thinking が偽のときと同じく、空の思考チャネルを置く）
        if !thinking {
            ids.append(self.special("<|channel>"))
            ids += self.base.encode("thought\n").map(Int.init)
            ids.append(self.special("<channel|>"))
        }
        return ids
    }
}

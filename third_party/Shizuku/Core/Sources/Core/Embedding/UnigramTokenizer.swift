import Foundation

// MARK: - 埋め込みモデルの字句分割（llm-ime、解析と学習 段階 B）
//
// ruri-v3 の tokenizer.json（SentencePiece の Unigram。正規化なし、空白を ▁ に置き換え、先頭には付けない、未知の文字はバイトに分ける、
// 先頭に <s>・末尾に </s>）を Swift だけで読む。分け方は Hugging Face tokenizers と同じ（Viterbi で得点の和が最大の分け方。
// 未知の文字は最小の得点 − 10）。結果が同じことは、変換の手順（tools/embedding）で確かめる。

public final class UnigramTokenizer: @unchecked Sendable {
    /// 字句（UTF-8 のバイト列で引く。Swift の String は正準等価な文字列を同じとみなすので、「です」と「て＋濁点＋す」が
    /// 別の字句として入っている語彙では、バイト列で比べないと Hugging Face tokenizers と分け方が変わる）
    private let pieces: [Data: (id: Int32, score: Double)]
    private let maxPieceLength: Int
    private let unkScore: Double
    public let unkID: Int32
    public let bosID: Int32
    public let eosID: Int32
    public let padID: Int32
    private let byteFallback: Bool
    private let byteIDs: [Int32]

    public init(tokenizerJSON url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = root["model"] as? [String: Any], model["type"] as? String == "Unigram",
              let vocab = model["vocab"] as? [[Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var pieces: [Data: (Int32, Double)] = [:]
        var maxLength = 1
        var minScore = 0.0
        for (index, entry) in vocab.enumerated() {
            guard let piece = entry.first as? String, let score = (entry.last as? NSNumber)?.doubleValue else {
                continue
            }
            let key = Data(piece.utf8)
            if pieces[key] == nil {
                pieces[key] = (Int32(index), score)
            }
            maxLength = max(maxLength, piece.unicodeScalars.count)
            minScore = min(minScore, score)
        }
        self.pieces = pieces
        self.maxPieceLength = maxLength
        self.unkScore = minScore - 10
        self.unkID = Int32(model["unk_id"] as? Int ?? 0)
        self.byteFallback = model["byte_fallback"] as? Bool ?? false
        self.bosID = pieces[Data("<s>".utf8)]?.0 ?? 1
        self.eosID = pieces[Data("</s>".utf8)]?.0 ?? 2
        self.padID = pieces[Data("<pad>".utf8)]?.0 ?? 3
        self.byteIDs = (0..<256).map { pieces[Data(String(format: "<0x%02X>", $0).utf8)]?.0 ?? Int32(model["unk_id"] as? Int ?? 0) }
    }

    /// 文を字句に分ける（<s>・</s> なし）
    public func encode(_ text: String) -> [Int32] {
        let scalars = Array(text.replacingOccurrences(of: " ", with: "\u{2581}").unicodeScalars)
        guard !scalars.isEmpty else {
            return []
        }
        // best[i]: i 文字目までの最良の得点と、その最後の字句（始まり・番号。番号が nil なら未知の文字）
        var best = [(score: Double, start: Int, id: Int32?)](repeating: (-.infinity, -1, nil), count: scalars.count + 1)
        best[0] = (0, -1, nil)
        for start in 0..<scalars.count where best[start].score > -.infinity {
            var covered = false
            var piece = Data()
            for length in 1...min(self.maxPieceLength, scalars.count - start) {
                piece.append(contentsOf: String(scalars[start + length - 1]).utf8)
                guard let entry = self.pieces[piece] else {
                    continue
                }
                if length == 1 {
                    covered = true
                }
                let score = best[start].score + entry.score
                if score > best[start + length].score {
                    best[start + length] = (score, start, entry.id)
                }
            }
            if !covered {
                let score = best[start].score + self.unkScore
                if score > best[start + 1].score {
                    best[start + 1] = (score, start, nil)
                }
            }
        }
        var ids: [Int32] = []
        var end = scalars.count
        while end > 0 {
            let node = best[end]
            if let id = node.id {
                ids.append(id)
            } else if self.byteFallback {
                let character = String(String.UnicodeScalarView(scalars[node.start..<end]))
                ids.append(contentsOf: character.utf8.reversed().map { self.byteIDs[Int($0)] })
            } else {
                ids.append(self.unkID)
            }
            end = node.start
        }
        return ids.reversed()
    }

    /// 決まった長さの入力（<s> 文 </s>、長ければ切り、短ければ <pad> で埋める）と、注意の印
    public func encode(_ text: String, length: Int) -> (ids: [Int32], mask: [Int32]) {
        var ids = [self.bosID] + self.encode(text).prefix(max(0, length - 2)) + [self.eosID]
        let used = ids.count
        ids += [Int32](repeating: self.padID, count: max(0, length - used))
        return (ids, [Int32](repeating: 1, count: used) + [Int32](repeating: 0, count: max(0, length - used)))
    }
}

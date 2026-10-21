import Foundation

/// llm-ime: Gemma 4 の BPE トークナイザ（Hugging Face tokenizers の tokenizer.json と同じ結果を返す）。
///
/// tokenizer.json の構成: 正規化で空白を「▁」に置き換え、事前分割はなし（空白は正規化で消えるため）、
/// Unicode スカラー単位の BPE、語彙にない文字は UTF-8 のバイトトークン（<0xXX>）に落とす。
/// 語彙と結合規則は gemma4/export_host.py が書き出す tokenizer.bin から読む。
public final class Gemma4Tokenizer: @unchecked Sendable {
    public let vocabularySize: Int
    public let bos: Int32 = 2
    /// 生成を止めるトークン（<eos>, <end_of_turn> など特殊トークン全般）
    public let specialIDs: Set<Int32>

    /// id → 表層（▁ は空白に戻し済み）。バイトトークンは空
    private let surfaces: [[UInt8]]
    /// id → バイトトークンの値（<0xXX>）。それ以外は -1
    private let byteValues: [Int16]
    /// 1 スカラーだけからなる語彙の id
    private let scalarIDs: [UInt32: Int32]
    /// バイト値 → <0xXX> の id
    private let byteIDs: [Int32]
    /// (左 id << 32 | 右 id) → (優先順位 << 32 | 結合後 id)
    private let merges: [UInt64: UInt64]
    /// 特殊トークンの表記（<|turn> など）→ id
    private let specialPieces: [String: Int32]

    public enum LoadError: Error {
        case invalidFormat(String)
    }

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var offset = 0
        func u32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw LoadError.invalidFormat("truncated")
            }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: v)
        }
        func u16() throws -> UInt16 {
            guard offset + 2 <= data.count else {
                throw LoadError.invalidFormat("truncated")
            }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            offset += 2
            return UInt16(littleEndian: v)
        }
        guard data.count > 16, data.prefix(4) == Data("G4TK".utf8) else {
            throw LoadError.invalidFormat("magic")
        }
        offset = 4
        guard try u32() == 1 else {
            throw LoadError.invalidFormat("version")
        }
        let vocabularySize = Int(try u32())
        let mergeCount = Int(try u32())
        let space = Array("▁".utf8)
        var surfaces: [[UInt8]] = []
        surfaces.reserveCapacity(vocabularySize)
        var byteValues = [Int16](repeating: -1, count: vocabularySize)
        var scalarIDs: [UInt32: Int32] = [:]
        var byteIDs = [Int32](repeating: -1, count: 256)
        for id in 0..<vocabularySize {
            let length = Int(try u16())
            guard offset + length <= data.count else {
                throw LoadError.invalidFormat("vocab")
            }
            let bytes = [UInt8](data[offset..<offset + length])
            offset += length
            let piece = String(decoding: bytes, as: UTF8.self)
            if length == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"), let value = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                byteValues[id] = Int16(value)
                byteIDs[Int(value)] = Int32(id)
                surfaces.append([])
                continue
            }
            let scalars = piece.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first {
                scalarIDs[scalar.value] = Int32(id)
            }
            surfaces.append(Self.replacing(bytes, space, with: [0x20]))
        }
        var merges: [UInt64: UInt64] = [:]
        merges.reserveCapacity(mergeCount)
        for rank in 0..<mergeCount {
            let a = UInt64(try u32()), b = UInt64(try u32()), merged = UInt64(try u32())
            merges[a << 32 | b] = UInt64(rank) << 32 | merged
        }
        let specialCount = Int(try u32())
        var specialIDs: Set<Int32> = []
        for _ in 0..<specialCount {
            specialIDs.insert(Int32(try u32()))
        }
        guard byteIDs.allSatisfy({ $0 >= 0 }) else {
            throw LoadError.invalidFormat("byte tokens")
        }
        self.vocabularySize = vocabularySize
        self.surfaces = surfaces
        self.byteValues = byteValues
        self.scalarIDs = scalarIDs
        self.byteIDs = byteIDs
        self.merges = merges
        self.specialIDs = specialIDs
        var specialPieces: [String: Int32] = [:]
        for id in specialIDs where Int(id) < surfaces.count {
            specialPieces[String(decoding: surfaces[Int(id)], as: UTF8.self)] = id
        }
        self.specialPieces = specialPieces
    }

    /// トークンの表記から id を引く（特殊トークンと 1 文字の語彙は表引き、それ以外は全語彙を走査する）。
    public func tokenID(forPiece piece: String) -> Int32? {
        if let id = self.specialPieces[piece] {
            return id
        }
        let normalized = piece.replacingOccurrences(of: "▁", with: " ")
        if normalized.unicodeScalars.count == 1, let scalar = piece.unicodeScalars.first, let id = self.scalarIDs[scalar.value] {
            return id
        }
        let bytes = Array(normalized.utf8)
        return self.surfaces.firstIndex(of: bytes).map { Int32($0) }
    }

    /// id のトークンの表記（バイトトークンは <0xXX>）。
    public func piece(for id: Int32) -> String? {
        guard id >= 0, Int(id) < self.vocabularySize else {
            return nil
        }
        let b = self.byteValues[Int(id)]
        if b >= 0 {
            return String(format: "<0x%02X>", b)
        }
        return String(decoding: self.surfaces[Int(id)], as: UTF8.self)
    }

    private static func replacing(_ bytes: [UInt8], _ pattern: [UInt8], with replacement: [UInt8]) -> [UInt8] {
        guard bytes.count >= pattern.count else {
            return bytes
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if i + pattern.count <= bytes.count, bytes[i..<i + pattern.count].elementsEqual(pattern) {
                out.append(contentsOf: replacement)
                i += pattern.count
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// テキストをトークン列にする（BOS は付けない）。
    public func encode(_ text: String) -> [Int32] {
        var symbols: [Int32] = []
        symbols.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let value = scalar == " " ? 0x2581 : scalar.value
            if let id = self.scalarIDs[value] {
                symbols.append(id)
            } else {
                symbols.append(contentsOf: String(scalar).utf8.map { self.byteIDs[Int($0)] })
            }
        }
        guard symbols.count >= 2 else {
            return symbols
        }
        // ranks[i] は (symbols[i], symbols[i+1]) の結合規則（なければ nil）
        var ranks: [UInt64?] = (0..<symbols.count - 1).map { self.merges[UInt64(UInt32(bitPattern: symbols[$0])) << 32 | UInt64(UInt32(bitPattern: symbols[$0 + 1]))] }
        while true {
            var best = -1
            var bestRank = UInt64.max
            for (i, r) in ranks.enumerated() {
                if let r, r >> 32 < bestRank {
                    bestRank = r >> 32
                    best = i
                }
            }
            guard best >= 0, let r = ranks[best] else {
                break
            }
            symbols[best] = Int32(truncatingIfNeeded: r & 0xFFFF_FFFF)
            symbols.remove(at: best + 1)
            ranks.remove(at: best)
            if best < ranks.count {
                ranks[best] = self.merges[UInt64(UInt32(bitPattern: symbols[best])) << 32 | UInt64(UInt32(bitPattern: symbols[best + 1]))]
            }
            if best > 0 {
                ranks[best - 1] = self.merges[UInt64(UInt32(bitPattern: symbols[best - 1])) << 32 | UInt64(UInt32(bitPattern: symbols[best]))]
            }
        }
        return symbols
    }

    /// トークン列の UTF-8 バイト列（skipSpecialTokens なら特殊トークンは除く）。
    public func bytes(_ ids: [Int32], skipSpecialTokens: Bool = true) -> [UInt8] {
        var out: [UInt8] = []
        for id in ids where id >= 0 && Int(id) < self.vocabularySize && !(skipSpecialTokens && self.specialIDs.contains(id)) {
            let b = self.byteValues[Int(id)]
            if b >= 0 {
                out.append(UInt8(b))
            } else {
                out.append(contentsOf: self.surfaces[Int(id)])
            }
        }
        return out
    }

    /// トークン列を文字列にする。末尾の不完全な UTF-8 は捨てる（生成途中の表示用）。
    public func decode(_ ids: [Int32]) -> String {
        self.string(fromBytes: self.bytes(ids))
    }

    /// UTF-8 バイト列を文字列にする。末尾の不完全な多バイト文字は捨てる。
    public func string(fromBytes bytes: [UInt8]) -> String {
        var bytes = bytes
        // 末尾の不完全な多バイト文字を落とす
        var cut = bytes.count
        var i = bytes.count - 1
        var continuation = 0
        while i >= 0 && bytes[i] & 0xC0 == 0x80 {
            continuation += 1
            i -= 1
        }
        if i >= 0 {
            let lead = bytes[i]
            let need = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
            if continuation < need {
                cut = i
            }
        }
        bytes.removeSubrange(cut...)
        return String(decoding: bytes, as: UTF8.self)
    }
}

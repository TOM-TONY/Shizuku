import Foundation

/// llm-ime: 入力欄のカーソルより前の文章に書いた漢字の語（「船底」など）を、今の読みで読めるかを 1 字ずつ確かめる。
/// 読めた語は動的ユーザー辞書の語として変換に渡す（辞書に「センテイ」の読みがない「船底」も候補になる）。
///
/// 1 字の読みは、変換の辞書で読み（1〜4 字）を引いて、1 字の候補に入っている漢字で決める（引いた結果は覚えておく）。
/// 辞書を引くのは遅いので、キーの処理では覚えている結果だけを使い、足りない読みは pending に積む。
/// pending は呼び出し側が裏で引き（DocumentReadingLookup）、結果を complete で渡す。
/// 1 字の候補の中の順位（よく使う読みほど前）を足した値を語の rank にし、同じ読みの語が複数あれば rank の小さい方を優先する
/// （「センテイ」は「船底」も「船体」も読めるが、「体」をテイと読むのはまれ）。文章・語・読みはメモリの中だけに持ち、保存しない。
public struct DocumentReadings: Sendable {
    public struct Entry: Hashable, Sendable {
        public let surface: String
        /// カタカナの読み
        public let ruby: String
        /// 1 字ずつの、1 字の候補の中の順位の合計（小さいほどよく使う読み）
        public let rank: Int
    }

    /// 語として拾う漢字の連なりの長さ
    public static let wordLengths = 2...4
    /// 1 字の読みとして引く長さ（「チュウ」「サムライ」まで）
    public static let maxPartLength = 4
    /// 1 つの語の読みの長さの上限
    public static let maxReadingLength = 12
    public static let maxWords = 400
    public static let maxEntries = 64
    public static let maxCachedParts = 4096
    /// 語の順位の合計の上限（まれな読みばかりを組み合わせた読みでは足さない）
    public static let maxRank = 60
    /// 漢字 1 字の読みの最初に来ない字（撥音・促音・長音・小書きの仮名）で始まる読みは引かない
    static let impossibleStarts: Set<Character> = ["ン", "ッ", "ー", "ァ", "ィ", "ゥ", "ェ", "ォ", "ャ", "ュ", "ョ", "ヮ"]

    private var document: String?
    /// 文章の語（カーソルに近い順）。最初の字ごとに引けるようにする
    public private(set) var words: [String] = []
    private var wordsByFirst: [Character: [String]] = [:]
    /// 読み（カタカナ）→ その読みで 1 字の候補になる漢字の順位
    private var singles: [String: [Character: Int]] = [:]
    private var singleOrder: [String] = []
    /// まだ辞書を引いていない読み（古い順）
    public private(set) var pending: [String] = []
    /// 見つけた語（新しい順）
    public private(set) var entries: [Entry] = []
    /// 計測用: 辞書を引いた回数
    public private(set) var lookups = 0

    public init() {}

    static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true
            default: false
            }
        }
    }

    /// 文章を単語に分け（CFStringTokenizer）、漢字だけの語と、隣り合う漢字の語をつないだもの（2〜4 字）を拾う
    /// （カーソルに近い順、重複なし）。漢字の連なりの途中で切れた部分（「自己位置」の「己位」など）は語にしない
    static func extractWords(_ document: String) -> [String] {
        var seen = Set<String>(), words: [String] = []
        for group in kanjiTokenGroups(document).reversed() {
            for start in group.indices.reversed() {
                var word = ""
                for token in group[start...] {
                    word += token
                    guard word.count <= wordLengths.upperBound else {
                        break
                    }
                    if word.count >= wordLengths.lowerBound, seen.insert(word).inserted {
                        words.append(word)
                    }
                }
            }
            if words.count >= maxWords {
                return Array(words.prefix(maxWords))
            }
        }
        return words
    }

    /// 漢字だけの単語の並び（間に別の字があれば区切る）
    private static func kanjiTokenGroups(_ document: String) -> [[String]] {
        let text = document as NSString
        guard text.length > 0 else {
            return []
        }
        let tokenizer = CFStringTokenizerCreate(nil, document as CFString, CFRange(location: 0, length: text.length),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale)
        var groups: [[String]] = [], current: [String] = [], end = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = text.substring(with: NSRange(location: range.location, length: range.length))
            let kanji = !token.isEmpty && token.allSatisfy(isKanji)
            if !current.isEmpty, !kanji || range.location != end {
                groups.append(current)
                current = []
            }
            if kanji {
                current.append(token)
            }
            end = range.location + range.length
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// 文章が変わったら語を拾い直す。文章に書かれていない語は見つけた語から外す
    public mutating func update(document: String) {
        guard document != self.document else {
            return
        }
        self.document = document
        self.words = Self.extractWords(document)
        self.wordsByFirst = Dictionary(grouping: self.words) { $0.first! }
        self.entries.removeAll { !document.contains($0.surface) }
    }

    public mutating func clear() {
        self.document = nil; self.words = []; self.wordsByFirst = [:]; self.entries = []; self.pending = []
    }

    /// target（カタカナ）の、末尾で終わる部分（allSubstrings なら全部の部分）に読める語を探す。新しく見つかったら true
    @discardableResult
    public mutating func match(target: String, allSubstrings: Bool = false) -> Bool {
        let reading = Array(target)
        guard reading.count >= 2, !self.words.isEmpty else {
            return false
        }
        var found = false
        let ends = allSubstrings ? Array(2...reading.count) : [reading.count]
        for end in ends {
            for start in stride(from: end - 2, through: max(0, end - Self.maxReadingLength), by: -1) {
                found = self.match(Array(reading[start..<end])) || found
            }
        }
        return found
    }

    private mutating func match(_ reading: [Character]) -> Bool {
        // 最初の字になれる漢字（引いていない読みは pending に積んで、今回は使わない）
        var firsts = Set<Character>()
        for length in 1...min(Self.maxPartLength, reading.count) {
            if let characters = self.lookupCached(String(reading[0..<length])) { firsts.formUnion(characters.keys) }
        }
        var found = false
        for first in firsts {
            for word in self.wordsByFirst[first] ?? [] where word.count <= reading.count && reading.count <= word.count * Self.maxPartLength {
                guard let rank = self.bestRank(Array(word), reading), rank <= Self.maxRank else {
                    continue
                }
                let ruby = String(reading)
                if let index = self.entries.firstIndex(where: { $0.surface == word && $0.ruby == ruby }) {
                    guard rank < self.entries[index].rank else {
                        continue
                    }
                    self.entries.remove(at: index)
                }
                self.entries.insert(Entry(surface: word, ruby: ruby, rank: rank), at: 0)
                if self.entries.count > Self.maxEntries { self.entries.removeLast() }
                found = true
            }
        }
        return found
    }

    /// word を 1 字ずつ reading の区切りに当てはめたときの、順位の合計の最小（当てはめられなければ nil）。
    /// 引いていない読みは pending に積み、読めないとみなす
    private mutating func bestRank(_ word: [Character], _ reading: [Character]) -> Int? {
        var reachable: [Int: Int] = [0: 0]
        for character in word {
            var next: [Int: Int] = [:]
            for (position, rank) in reachable {
                for length in 1...Self.maxPartLength where position + length <= reading.count {
                    if let order = self.lookupCached(String(reading[position..<(position + length)]))?[character] {
                        next[position + length] = min(next[position + length] ?? .max, rank + order)
                    }
                }
            }
            reachable = next
            if reachable.isEmpty {
                return nil
            }
        }
        return reachable[reading.count]
    }

    private mutating func lookupCached(_ part: String) -> [Character: Int]? {
        if let characters = self.singles[part] {
            return characters
        }
        if let first = part.first, Self.impossibleStarts.contains(first) {
            return [:]
        }
        if !self.pending.contains(part) { self.pending.append(part) }
        return nil
    }

    /// 裏で引いた結果（変換の順）を覚える
    public mutating func complete(_ part: String, _ characters: [Character]) {
        self.pending.removeAll { $0 == part }
        self.store(part, characters)
    }

    /// 計測・試験用: 1 字の読みを直接覚えさせる（characters は変換の順）
    public mutating func store(_ part: String, _ characters: [Character]) {
        self.lookups += 1
        var order: [Character: Int] = [:]
        for character in characters where Self.isKanji(character) && order[character] == nil {
            order[character] = order.count
        }
        if self.singles.updateValue(order, forKey: part) == nil {
            self.singleOrder.append(part)
            if self.singleOrder.count > Self.maxCachedParts {
                self.singles[self.singleOrder.removeFirst()] = nil
            }
        }
    }
}

import Foundation
import NaturalLanguage

/// 開き閉じの表。単語の境界を両端で確かめる。単漢字は隣の漢字・数字も拒否する。
public enum PersonalOrthography {
    public struct Pair: Sendable {
        public let closed: String
        public let open: String
        public let rejectsAdjacentHanOrDigit: Bool
        init(_ closed: String, _ open: String) {
            self.closed = closed; self.open = open
            self.rejectsAdjacentHanOrDigit = closed.count == 1
        }
    }
    // 「様」「位」「何時」は宛名・順位・時刻との区別が難しいため入れない。
    public static let pairs: [Pair] = [
        .init("下さい", "ください"), .init("致します", "いたします"), .init("出来る", "できる"),
        .init("有難う", "ありがとう"), .init("宜しく", "よろしく"), .init("頂く", "いただく"),
        .init("事", "こと"), .init("時", "とき"), .init("物", "もの"), .init("為", "ため"),
        .init("迄", "まで"), .init("又", "また"), .init("更に", "さらに"), .init("既に", "すでに"),
        .init("全て", "すべて"), .init("殆ど", "ほとんど"), .init("是非", "ぜひ"), .init("等", "など"),
        .init("及び", "および"), .init("尚", "なお"), .init("但し", "ただし"), .init("予め", "あらかじめ"),
        .init("概ね", "おおむね"), .init("程", "ほど"), .init("貰う", "もらう"), .init("言う", "いう"),
        .init("行う", "おこなう"), .init("無い", "ない"), .init("良い", "よい"), .init("沢山", "たくさん"),
        .init("丁度", "ちょうど"), .init("何故", "なぜ"), .init("何処", "どこ"), .init("何れ", "いずれ"),
        .init("未だ", "まだ"), .init("直ぐ", "すぐ"), .init("暫く", "しばらく"), .init("敢えて", "あえて"),
        .init("例えば", "たとえば"), .init("即ち", "すなわち")
    ]
    static let variants: [String: (index: Int, side: Int)] = {
        var result: [String: (Int, Int)] = [:]
        for (index, pair) in pairs.enumerated() { result[pair.closed] = (index, 0); result[pair.open] = (index, 1) }
        return result
    }()
    static let expression = try! NSRegularExpression(pattern: variants.keys.sorted {
        $0.count != $1.count ? $0.count > $1.count : $0 < $1
    }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))

    /// 分かち書き器は準備時に読み込み、候補ごとに作らない。本文を残さないよう走査後にstringを空にする。
    final class Words: @unchecked Sendable {
        private let lock = NSLock()
        private let tokenizer = NLTokenizer(unit: .word)
        init() {
            tokenizer.setLanguage(.japanese)
            _ = boundaries("確認しました。")
        }
        func boundaries(_ text: String) -> Set<String.Index> {
            lock.lock(); defer { tokenizer.string = nil; lock.unlock() }
            tokenizer.string = text
            var result: Set<String.Index> = [text.startIndex, text.endIndex]
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                result.insert(range.lowerBound); result.insert(range.upperBound); return true
            }
            return result
        }
    }
    static let observationWords = Words()
    static func matches(_ text: String, words: Words, boundaries supplied: (() -> Set<String.Index>)? = nil) -> [(range: Range<String.Index>, index: Int, side: Int)] {
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return [] }
        let boundaries = supplied?() ?? words.boundaries(text)
        func isHanOrDigit(_ character: Character) -> Bool {
            character.unicodeScalars.contains { scalar in
                scalar.properties.numericType != nil || (0x3400...0x9fff).contains(scalar.value) || (0x20000...0x323af).contains(scalar.value)
            }
        }
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text), boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound),
                  let variant = variants[String(text[range])] else { return nil }
            if pairs[variant.index].rejectsAdjacentHanOrDigit {
                if range.lowerBound > text.startIndex, isHanOrDigit(text[text.index(before: range.lowerBound)]) { return nil }
                if range.upperBound < text.endIndex, isHanOrDigit(text[range.upperBound]) { return nil }
            }
            return (range, variant.index, variant.side)
        }
    }
}

/// 数だけの表記プロファイル。本文は保持しない。観測・Planの準備は書き込みキュー、適用は生成後だけ。
public struct PersonalStyleProfile: Sendable {
    public struct Count: Sendable, Equatable {
        public var first = 0
        public var second = 0
        public var observations: Int { first + second }
        public func preference(minimum: Int) -> Int? {
            guard observations >= minimum else { return nil }
            if first * 5 >= observations * 4 { return 0 }
            if second * 5 >= observations * 4 { return 1 }
            return nil
        }
    }
    // 0=文末の句点、1=!、2=?、3=読点、4=括弧、5=数字、6以降=開き閉じ。
    public private(set) var counts: [String: [Count]] = [:]
    public private(set) var honorificCounts: [String: [Int: Int]] = [:]
    public init() {}
    public static func read(store: PersonalStore) throws -> PersonalStyleProfile {
        var result = PersonalStyleProfile()
        try store.query("SELECT scene,surface FROM commits WHERE origin IN (0,2) AND kind IN ('selection','enter','transform','kana') ORDER BY ts,id") {
            if let scene = PersonalScene(key: $0.text(0) ?? "") { result.observe(scene: scene, text: $0.text(1) ?? "") }
        }
        return result
    }
    public static func levels(_ scene: PersonalScene?) -> [String] {
        guard let scene else { return ["global"] }
        return scene.levelKeys
    }
    public mutating func observe(scene: PersonalScene, text: String) {
        let width = PersonalOrthography.pairs.count + 6
        var values = [Count](repeating: .init(), count: width)
        func count(_ feature: Int, _ side: Int) {
            if side == 0 { values[feature].first += 1 } else { values[feature].second += 1 }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { count(0, trimmed.hasSuffix("。") ? 0 : 1) }
        var opens = [0, 0], closes = [0, 0]
        for character in text {
            switch character {
            case "！": count(1, 0)
            case "!": count(1, 1)
            case "？": count(2, 0)
            case "?": count(2, 1)
            case "、": count(3, 0)
            case "，": count(3, 1)
            case "（": opens[0] += 1
            case "(": opens[1] += 1
            case "）": closes[0] += 1
            case ")": closes[1] += 1
            default:
                if let value = character.unicodeScalars.first?.value, character.unicodeScalars.count == 1 {
                    if (0xff10...0xff19).contains(value) { count(5, 0) }
                    else if (0x30...0x39).contains(value) { count(5, 1) }
                }
            }
        }
        values[4] = Count(first: min(opens[0], closes[0]), second: min(opens[1], closes[1]))
        for match in PersonalOrthography.matches(text, words: PersonalOrthography.observationWords) { count(match.index + 6, match.side) }
        let honorifics = PersonalHonorific.matches(text, words: PersonalOrthography.observationWords)
        for level in Self.levels(scene) {
            var current = counts[level] ?? [Count](repeating: .init(), count: width)
            for i in current.indices { current[i].first += values[i].first; current[i].second += values[i].second }
            counts[level] = current
            for match in honorifics { honorificCounts[level, default: [:]][match.id, default: 0] += 1 }
        }
    }
    public init(rows: [LabCommit]) {
        self.init()
        for row in rows where row.isMaterial && PersonalOrigin.normalKinds.contains(row.kind) {
            if let scene = PersonalScene(key: row.scene) { observe(scene: scene, text: row.surface) }
        }
    }
    public func preferences(levels: [String]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for feature in 0..<(PersonalOrthography.pairs.count + 6) {
            for level in levels {
                if let count = counts[level]?[feature], let side = count.preference(minimum: feature >= 6 ? 5 : 10) {
                    result[feature] = side; break
                }
            }
        }
        return result
    }
    public func plans(reusing previous: [String: PersonalStylePlan] = [:]) -> [String: PersonalStylePlan] {
        var result: [String: PersonalStylePlan] = [:]
        for key in counts.keys.sorted() {
            let levels: [String]
            if let scene = PersonalScene(key: key) { levels = Self.levels(scene) }
            else { levels = key == "global" ? [key] : [key, "global"] }
            let choices = preferences(levels: levels)
            let usage = honorificUsage(levels: levels)
            if !choices.isEmpty || !usage.isEmpty {
                result[key] = previous[key].flatMap { $0.preferences == choices && $0.honorificUsage == usage ? $0 : nil }
                    ?? PersonalStylePlan(preferences: choices, honorificUsage: usage)
            }
        }
        return result
    }
    /// 対ごとに2回以上の語がある最も細かい段。未達なら最初に観測した段の数を残し、置換しない。
    public func honorificUsage(levels: [String]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for group in PersonalHonorific.groupIDs {
            var first: [Int: Int]?
            for level in levels {
                let values = Dictionary(uniqueKeysWithValues: group.compactMap { id in
                    honorificCounts[level]?[id].map { (id, $0) }
                })
                if values.isEmpty { continue }
                if first == nil { first = values }
                if values.values.contains(where: { $0 >= 2 }) { first = values; break }
            }
            if let first { result.merge(first) { _, new in new } }
        }
        return result
    }
}

public final class PersonalStylePlan: @unchecked Sendable {
    public let preferences: [Int: Int]
    public let honorificUsage: [Int: Int]
    private let honorificReplacements: [Int: Int]
    private let words: PersonalOrthography.Words?
    public init(preferences: [Int: Int], honorificUsage: [Int: Int] = [:]) {
        self.preferences = preferences
        self.honorificUsage = honorificUsage
        self.honorificReplacements = PersonalHonorific.replacements(usage: honorificUsage)
        self.words = preferences.keys.contains { $0 >= 6 } || !honorificReplacements.isEmpty ? PersonalOrthography.Words() : nil
        // 正規表現・分かち書き器の最初の準備も、本文を返す前の裏の準備に含める。
        if !isEmpty { _ = apply("事務と記事をご確認下さい。（予定）１，２！") }
    }
    public var isEmpty: Bool { preferences.isEmpty && honorificReplacements.isEmpty }
    /// honorifics が false なら待遇語は置き換えず、表記だけ寄せる（AI への指示の場面）
    public func apply(_ text: String, honorifics: Bool = true) -> String {
        guard !isEmpty, !text.isEmpty else { return text }
        var output = text
        if let words {
            // 表記と待遇語は同じ原文の境界を一度だけ求め、重なる場合は本人の待遇語を優先する。
            var cached: Set<String.Index>?
            func boundaries() -> Set<String.Index> {
                if let cached { return cached }
                let result = words.boundaries(text); cached = result; return result
            }
            var edits: [(range: Range<String.Index>, text: String)] = []
            if honorifics, !honorificReplacements.isEmpty {
                edits = PersonalHonorific.matches(text, words: words, boundaries: boundaries).compactMap { match in
                    honorificReplacements[match.id].map { (match.range, PersonalHonorific.variants[$0]) }
                }
            }
            let honorificRanges = edits.map(\.range)
            for match in PersonalOrthography.matches(text, words: words, boundaries: boundaries) {
                guard let preferred = preferences[match.index + 6], preferred != match.side,
                      !honorificRanges.contains(where: { $0.overlaps(match.range) }) else { continue }
                let pair = PersonalOrthography.pairs[match.index]
                edits.append((match.range, preferred == 0 ? pair.closed : pair.open))
            }
            var parts = "", previous = text.startIndex
            for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                parts += text[previous..<edit.range.lowerBound]; parts += edit.text
                previous = edit.range.upperBound
            }
            if previous != text.startIndex { parts += text[previous...]; output = parts }
        }
        var transformed = String.UnicodeScalarView()
        for scalar in output.unicodeScalars {
            var value = scalar.value
            switch value {
            case 0xff01, 0x21: if let side = preferences[1] { value = side == 0 ? 0xff01 : 0x21 }
            case 0xff1f, 0x3f: if let side = preferences[2] { value = side == 0 ? 0xff1f : 0x3f }
            case 0x3001, 0xff0c: if let side = preferences[3] { value = side == 0 ? 0x3001 : 0xff0c }
            case 0xff08, 0x28: if let side = preferences[4] { value = side == 0 ? 0xff08 : 0x28 }
            case 0xff09, 0x29: if let side = preferences[4] { value = side == 0 ? 0xff09 : 0x29 }
            case 0xff10...0xff19: if preferences[5] == 1 { value -= 0xfee0 }
            case 0x30...0x39: if preferences[5] == 0 { value += 0xfee0 }
            default: break
            }
            transformed.append(UnicodeScalar(value)!)
        }
        output = String(transformed)
        if let side = preferences[0] {
            if side == 1, output.hasSuffix("。") { output.removeLast() }
            else if side == 0, let last = output.last, !"。！？!?\n」』）)".contains(last) { output += "。" }
        }
        return output
    }
}

/// 生成結果の通り道を固定する。添削・変換候補・入力中のE4Bのpiecesは正規化しない。
public enum PersonalGeneratedText {
    public enum Route: Sendable { case magic, transform, draft, idle, proofread, conversion, completion }
    public static func apply(_ text: String, route: Route, enabled: Bool, plan: PersonalStylePlan?, honorifics: Bool = true) -> String {
        switch route {
        case .proofread, .conversion, .completion: return text
        case .magic, .transform, .draft, .idle: return enabled ? plan?.apply(text, honorifics: honorifics) ?? text : text
        }
    }
}

import Foundation

/// 読みの対応が分かる内容語だけを照合し、単に漢字になった読みを欠落と数えない。
public enum PersonalFragments {
    public struct Token: Sendable {
        public var surface: String
        public var reading: String
        public init(surface: String, reading: String) { self.surface = surface; self.reading = reading }
    }
    private static let particles: Set<String> = ["は", "が", "を", "に", "で", "と", "も", "へ", "の", "です", "ます", "する", "した", "して", "ください", "だ", "た"]
    private static func key(_ value: String) -> String {
        value.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
            .toKatakana().filter { !$0.isWhitespace }
    }
    public static func missing(input: String, output: String, tokens: [Token]) -> [String] {
        let result = key(output)
        var seen = Set<String>()
        let candidates = tokens.map { ($0.surface, [$0.surface, $0.reading]) }
            + input.split(whereSeparator: { $0.isWhitespace }).filter { part in
                // 分かち書きのない読み全体は「断片」として推測しない。
                input.contains(where: { $0.isWhitespace }) || (part.allSatisfy(\.isASCII) && part.contains(where: { $0.isLetter || $0.isNumber }))
            }.map { (String($0), [String($0)]) }
        return candidates.compactMap { surface, aliases in
            let clean = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !particles.contains(clean), clean.count <= 40,
                  !PersonalPrivacy.looksSecret(clean),
                  !aliases.contains(where: { !key($0).isEmpty && result.contains(key($0)) }),
                  seen.insert(key(clean)).inserted else { return nil }
            return clean
        }
    }
}

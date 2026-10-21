import Foundation

public enum PersonalQuotes {
    public static func candidates(corpus: PersonalCorpus, scene: PersonalScene, context: String) -> [String] {
        let ranked = corpus.retrieve(query: String(context.suffix(40)), scene: scene, excluding: context, limit: 3, quoteOnly: true)
        let source = ranked.isEmpty ? corpus.sentences.enumerated().sorted {
            let a = $0.element, b = $1.element
            let aHere = a.baseScene == scene.baseKey, bHere = b.baseScene == scene.baseKey
            if aHere != bHere { return aHere }
            return a.ts == b.ts ? $0.offset > $1.offset : a.ts > b.ts
        }.map(\.element) : ranked
        var result: [String] = []
        for sentence in source where sentence.origin != 3 && sentence.app == scene.app {
            let text = String(sentence.text.prefix(50))
            guard !text.isEmpty, !context.contains(text), !PersonalPrivacy.looksSecret(sentence.text),
                  !result.contains(text) else { continue }
            result.append(text)
            if result.count == 3 { break }
        }
        return result
    }
}

/// 2分後の確認。観測窓に原文が見つからず全文脈でもない場合は、削除と断定せず欠測にする。
public struct AssistanceRetention: Sendable {
    public var text: String
    public var started: Double
    public init(text: String, started: Double) { self.text = text; self.started = started }
    public func retained(left: String?, complete: Bool, now: Double) -> Int? {
        guard now - started >= 120, now - started <= 600, let left else { return nil }
        if left.contains(text) { return text.count }
        var prefix = text
        while !prefix.isEmpty {
            prefix.removeLast()
            if !prefix.isEmpty, left.contains(prefix) { return prefix.count }
        }
        return complete ? 0 : nil
    }
}

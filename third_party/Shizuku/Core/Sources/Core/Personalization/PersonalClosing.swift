import Foundation

/// 締めの記録だけ。提案の経路は持たない。
public enum PersonalClosing {
    public static func extract(_ text: String) -> String? {
        guard let sentence = PersonalFieldContext.lastSentence(text),
              sentence.count >= PersonalOpening.minimumLength,
              sentence.count <= PersonalOpening.maximumLength,
              !PersonalPrivacy.looksSecret(sentence) else { return nil }
        return sentence
    }
    public struct Capture: Sendable {
        public var scene: PersonalScene
        public private(set) var text = ""
        public private(set) var sources: [Int64] = []
        public init(scene: PersonalScene) { self.scene = scene }
        public mutating func append(_ surface: String, source: Int64, authored: Bool) {
            guard authored, !PersonalPrivacy.looksSecret(surface) else { text = ""; sources = []; return }
            text = String((text + surface).suffix(2000))
            sources.append(source)
            if sources.count > 2000 { sources.removeFirst(sources.count - 2000) }
        }
        public mutating func observe(left: String?, deleted: Bool = false) {
            if deleted || (left.map { !$0.isEmpty && !text.isEmpty && !text.hasSuffix($0) && !$0.hasSuffix(text) } ?? false) {
                text = ""; sources = []
            }
        }
        public var closing: String? { PersonalClosing.extract(text) }
    }
}

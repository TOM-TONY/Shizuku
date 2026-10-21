import Foundation

/// 明示して覚えた手本。確定や本人の文体・自動辞書の学習から独立した出所。
public enum PersonalTeaching {
    public static let origin = 3
    public static let sceneLimit = 20
    public static let undoSeconds = 10.0
    public struct Entry: Sendable {
        public var id: String, batch: String, scene: String, app: String, text: String
        public var ts: Double
    }
    public static func sentences(_ text: String) -> [String]? {
        guard text.count <= 2400, !PersonalPrivacy.looksSecret(text) else { return nil }
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines), result: [String] = []
        while !remaining.isEmpty {
            let chunk = AssistanceVerbs.chunk(remaining, all: false)
            let sentence = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...PersonalCorpus.maxSentenceLength).contains(sentence.count),
                  !PersonalPrivacy.looksSecret(sentence), result.count < sceneLimit else { return nil }
            result.append(sentence); remaining = chunk.remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }
    public static func read(store: PersonalStore) throws -> [Entry] {
        var entries: [Entry] = []
        try store.query("SELECT id,batch,scene,app,text,ts FROM taught WHERE origin=3 ORDER BY ts,id") {
            entries.append(.init(id: $0.text(0) ?? "", batch: $0.text(1) ?? "", scene: $0.text(2) ?? "", app: $0.text(3) ?? "", text: $0.text(4) ?? "", ts: $0.double(5)))
        }
        return entries
    }
}

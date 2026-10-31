import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// llm-ime: DocumentReadings の 1 字の読みを、変換とは別の辞書のインスタンスで、裏のキューで引く。
/// 辞書を引くのは 1 回 数ms〜100ms かかるので、キーを処理する主スレッドを止めない。学習・ユーザー辞書は使わない
/// （本人の記録に触れず、変換の側の学習の読み込みや途中の結果も乱さない）。
public final class DocumentReadingLookup: @unchecked Sendable {
    public static let shared = DocumentReadingLookup()

    private let queue = DispatchQueue(label: "Shizuku.document-readings", qos: .utility)
    /// queue の上だけで使う
    private var converter: KanaKanjiConverter?
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shizuku-document-readings", isDirectory: true)

    public init() {}

    /// reading（カタカナ）で 1 字の候補になる漢字を、変換の順（よく使う読みが先）で返す
    public func lookUp(_ reading: String, completion: @escaping @Sendable ([Character]) -> Void) {
        self.queue.async {
            completion(self.run(reading))
        }
    }

    /// 試験・計測用: 呼んだスレッドで結果を待つ
    public func lookUpNow(_ reading: String) -> [Character] {
        self.queue.sync { self.run(reading) }
    }

    private func run(_ reading: String) -> [Character] {
        let converter = self.converter ?? KanaKanjiConverter.withDefaultDictionary()
        self.converter = converter
        var text = ComposingText()
        text.insertAtCursorPosition(reading, inputStyle: .direct)
        let options = ConvertRequestOptions(
            requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
            learningType: .nothing, memoryDirectoryURL: self.directory, sharedContainerURL: self.directory,
            textReplacer: .empty, specialCandidateProviders: [], zenzaiMode: .off, typoCorrectionMode: .disabled, metadata: nil
        )
        var seen = Set<Character>(), characters: [Character] = []
        for candidate in converter.requestCandidates(text, options: options).mainResults
        where candidate.data.count == 1 && candidate.text.count == 1 && candidate.data[0].ruby == reading {
            if let character = candidate.text.first, DocumentReadings.isKanji(character), seen.insert(character).inserted {
                characters.append(character)
            }
        }
        return characters
    }
}

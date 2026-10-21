import Foundation

/// llm-ime: AI への指示の場面で「2」「2で」「案B」のような短い確定が、画面のどの選択肢を指すかを示す。
/// 入力は書き換えない。選択肢の行が画面に 1 つだけ見つかったときだけ、その行（最大 80 字）を返す
public enum ShortReplyHint {
    public static let maximumInput = 10
    static let circled: [Character] = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]

    /// 短い確定から選択肢の印（"2"・"B"）を取り出す。選択肢を指していなければ nil
    public static func option(in text: String) -> String? {
        var body = text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= maximumInput else { return nil }
        for suffix in ["でお願いします", "でお願い", "で進めて", "でいい", "でいこう", "にして", "番目", "番", "案", "で", "。", "!", "！"] where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count))
        }
        for prefix in ["案", "オプション", "option", "Option", "No.", "no."] where body.hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if let index = circled.firstIndex(where: { String($0) == body }) { return String(index + 1) }
        if let number = Int(body), (1...20).contains(number) { return String(number) }
        if body.count == 1, let char = body.uppercased().first, ("A"..."H").contains(char) { return String(char) }
        return nil
    }

    static func markers(for option: String) -> [String] {
        var result = ["\(option).", "\(option))", "\(option)、", "\(option):", "\(option)：", "(\(option))", "（\(option)）",
                      "案\(option)", "Option \(option)", "option \(option)", "**\(option).", "- \(option)."]
        if let number = Int(option), (1...9).contains(number) { result.append(String(circled[number - 1])) }
        return result
    }

    public static func resolve(_ text: String, reference: WindowReference) -> String? {
        guard let option = option(in: text) else { return nil }
        let markers = markers(for: option)
        var found: [String] = []
        for block in reference.blocks {
            for raw in block.text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.count > option.count + 1, markers.contains(where: { line.hasPrefix($0) }) else { continue }
                if !found.contains(line) { found.append(line) }
            }
        }
        // 同じ印の行が複数あれば、どれを指すか分からないので出さない
        guard found.count == 1, let line = found.first else { return nil }
        return String(line.prefix(80))
    }
}

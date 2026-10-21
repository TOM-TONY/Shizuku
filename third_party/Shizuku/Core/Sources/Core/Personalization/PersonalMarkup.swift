import Foundation

/// Serverだけで使う記法の弱い規則。等幅だけではcodeにせず、記法も必要。
public enum PersonalMarkup {
    public static func shape(left: String, right: String, monospaced: Bool) -> PersonalScene.Shape? {
        let text = left + right
        let lines = text.components(separatedBy: .newlines)
        if text.contains("```") { return .code }
        var markdown = false, code = false, quote = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["# ", "## ", "### ", "#### ", "##### ", "###### ", "- ", "* "].contains(where: trimmed.hasPrefix) { markdown = true }
            if trimmed.hasPrefix("> ") { quote = true }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { code = true }
            if trimmed.contains("`"), trimmed.filter({ $0 == "`" }).count >= 2 { markdown = true }
            if monospaced && ["let ", "var ", "func ", "def ", "class ", "import ", "const ", "return ", "//", "if ("].contains(where: trimmed.hasPrefix) { code = true }
        }
        if monospaced && code { return .code }
        if markdown || (monospaced && quote) { return .md }
        return nil
    }
    public static func body(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.map { line in
            var value = line.trimmingCharacters(in: .whitespaces)
            while value.hasPrefix("> ") { value.removeFirst(2) }
            if let first = value.first, first == "#" {
                let rest = value.drop(while: { $0 == "#" })
                if rest.first == " " { value = String(rest.dropFirst()) }
            }
            if value.hasPrefix("- ") || value.hasPrefix("* ") { value.removeFirst(2) }
            return value.replacingOccurrences(of: "`", with: "")
        }.joined(separator: "\n")
    }
}

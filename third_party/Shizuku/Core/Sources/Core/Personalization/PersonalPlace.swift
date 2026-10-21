import CryptoKit
import Foundation

// MARK: - 場面の場所（アクセシビリティ、任意）（llm-ime、フェーズ 4）
//
// 本人がシステム設定でアクセシビリティを許可したときだけ、ConverterServer が入力欄の場所を読み取り、場面を細かく分ける
// （Chrome の Gmail と GitHub、Slack のチャンネル）。保存するのはサイトのホスト名か、入力欄の案内文から作った短い符号だけで、
// ページの本文・題・案内文そのものは保存しない。許可がなければ（または読めなければ）場所はなく、場面は今と同じ。

public enum PersonalPlace {
    /// URL からホスト名（http/https だけ。小文字にし、先頭の "www." を除く）。ほかの scheme（file・about・chrome・data・blob・拡張機能など）、
    /// ホストのない URL は nil
    public static func host(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        guard !host.isEmpty, !host.contains("|") else {
            return nil
        }
        return host
    }

    /// どこにでもある案内文（場所の手がかりにならない）
    static let genericPlaceholders: Set<String> = [
        "検索", "search", "メッセージ", "message", "メッセージを入力", "type a message", "write a message", "入力", "コメント",
        "comment", "add a comment", "返信", "reply", "テキスト", "text", "aa",
    ]

    /// 入力欄の案内文から場所の符号（"ph:" ＋ 6 桁の 16 進）。空・ありふれた案内文なら nil。符号は Mac の外に出さない
    public static func placeholderLabel(_ placeholder: String) -> String? {
        let normalized = placeholder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 2, !Self.genericPlaceholders.contains(normalized) else {
            return nil
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "ph:" + digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}

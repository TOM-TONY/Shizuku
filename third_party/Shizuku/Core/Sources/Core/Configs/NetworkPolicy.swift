import Foundation

/// llm-ime: 完全ローカル版のため、外部との通信をすべて無効化する。
///
/// OpenAI 互換 API への送信と、誤字訂正用重みのダウンロードはこのフラグで遮断する。
/// IME 本体はエンタイトルメントからも `network.client` を外しており、OS レベルでも通信できない。
public enum NetworkPolicy {
    public static let isNetworkAccessAllowed = false
}

public enum NetworkDisabledError: LocalizedError, Sendable {
    case disabled

    public var errorDescription: String? {
        "このビルドでは外部との通信を無効化しています"
    }
}

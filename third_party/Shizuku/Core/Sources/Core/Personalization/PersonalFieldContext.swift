import Foundation

/// 欄の本人の確定だけを保持する。永続化せず、復元の根拠が失われたら捨てる。
public struct PersonalFieldContext: Sendable {
    public private(set) var buffer = ""
    public private(set) var sent: (text: String, ts: Double)?
    public init() {}
    public mutating func append(_ text: String, authored: Bool) {
        guard authored, !PersonalPrivacy.looksSecret(text) else { buffer = ""; return }
        buffer = String((buffer + text).suffix(2000))
    }
    public mutating func reset() { buffer = ""; sent = nil }
    public mutating func finish(now: Double, sent: Bool) {
        self.sent = sent ? Self.lastSentence(buffer).map { ($0, now) } : nil
        buffer = ""
    }
    /// Chromium の既知の100字の切り詰めだけを補う。nil・空・不一致から推測しない。
    public mutating func restoredLeft(_ left: String?) -> String? {
        guard let left else { buffer = ""; return nil }
        guard !left.isEmpty else { return left }
        guard buffer.hasSuffix(left) else { buffer = ""; return left }
        return left.count == 100 && buffer.count > 100 ? buffer : left
    }
    public func completionLeft(_ left: String, now: Double) -> String {
        guard let sent, now >= sent.ts, now - sent.ts <= 120 else { return left }
        return String((sent.text + "\n" + left).suffix(2000))
    }
    public static func lastSentence(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // 末尾の「！？」などは一組として残し、その直前の文末・改行より後ろを取る。
        var ending = ""
        while let last = value.last, "。！？!?".contains(last) { ending.insert(value.removeLast(), at: ending.startIndex) }
        guard !value.isEmpty else { return nil }
        let start = value.lastIndex(where: { "。！？!?\n".contains($0) }).map { value.index(after: $0) } ?? value.startIndex
        let sentence = (String(value[start...]) + ending).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty || PersonalPrivacy.looksSecret(sentence) ? nil : sentence
    }
}

/// アプリをまたぐ手本。除外アプリを通った場合は出所も持ち越し先も破棄する。
public struct PersonalAppCarry: Sendable {
    private var app: String?
    private var own = ""
    private var carry: (text: String, ts: Double)?
    public init() {}
    public mutating func observe(app: String, allowed: Bool, now: Double, previousApp: String? = nil) {
        guard allowed else { self = Self(); return }
        if self.app != app {
            if let previousApp, self.app != previousApp { own = "" }
            carry = own.isEmpty ? nil : (String(own.suffix(200)), now)
            own = ""
            self.app = app
        }
    }
    public mutating func append(_ text: String, app: String, authored: Bool) {
        guard self.app == app, authored, !PersonalPrivacy.looksSecret(text) else { return }
        own = String((own + text).suffix(200))
    }
    public mutating func discardOwn(app: String) { if self.app == app { own = "" } }
    public func prefix(now: Double, app: String? = nil) -> String {
        if let app, self.app != app { return "" }
        guard let carry, now >= carry.ts, now - carry.ts <= 120 else { return "" }
        return carry.text + "\n"
    }
}

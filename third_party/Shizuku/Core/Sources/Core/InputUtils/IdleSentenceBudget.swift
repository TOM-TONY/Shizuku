/// 既存クライアントは一続きに最大3文を要求し、nilの返答でその列を止める。
/// 上限で止めた要求と3文目で状態を消すため、学習オフで採用通知が来なくても次のTab後に再開できる。
public struct IdleSentenceBudget: Sendable {
    private var expected: String?
    private var count = 0
    public init() {}
    public mutating func reset() { expected = nil; count = 0 }
    public mutating func permits(contextHash: String, limit: Int) -> Bool {
        if expected != contextHash { reset() }
        guard count < limit else { reset(); return false }
        return true
    }
    public mutating func emitted(nextContextHash: String) {
        count += 1
        if count >= 3 { reset() } else { expected = nextContextHash }
    }
}

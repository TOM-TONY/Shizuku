import Foundation

/// 応答待ちのキーが、どれだけの間まったく進んでいないかを数える。
///
/// Server が応答しない間、Client はキーを consume したまま再送を続ける。短い詰まりは
/// 順番どおりの再生で復帰できるが、長い停止では打鍵が表示されないまま溜まり続ける。
/// この時計が上限を超えたら、Client は待つのをやめて保留を破棄する。
public struct PendingKeyWatch: Sendable, Equatable {
    public let limit: TimeInterval
    public private(set) var waitingSince: TimeInterval?

    public init(limit: TimeInterval) {
        self.limit = limit
    }

    /// 応答待ちが 0 件の状態からキーを受け取ったときに、時計を始める。
    public mutating func keyQueued(at now: TimeInterval) {
        if waitingSince == nil {
            waitingSince = now
        }
    }

    /// Server がキーに応答した。まだ待っているキーがあれば、そこから数え直す。
    public mutating func keyAnswered(at now: TimeInterval, stillPending: Bool) {
        waitingSince = stillPending ? now : nil
    }

    public mutating func reset() {
        waitingSince = nil
    }

    /// 上限までの残り時間。待っているキーがなければ nil。
    public func remaining(at now: TimeInterval) -> TimeInterval? {
        waitingSince.map { limit - (now - $0) }
    }

    public func waited(at now: TimeInterval) -> TimeInterval {
        waitingSince.map { max(0, now - $0) } ?? 0
    }

    public func isStalled(at now: TimeInterval) -> Bool {
        remaining(at: now).map { $0 <= 0 } ?? false
    }
}

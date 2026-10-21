import Foundation

/// 打鍵が来たら新しい生成を止め、実行中の呼び出しが抜けるのを最大8msだけ待つ。
/// 待ちの期限には単調時計を使う。期限後も変換は必ず実行する。
public final class InferencePreemption: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var keys = 0
    private var active = 0
    var waitOverride: ((TimeInterval) -> Bool)?
    public init() {}
    public var keyPending: Bool { lock.withLock { keys > 0 } }
    public func enter() -> Bool {
        lock.withLock {
            guard keys == 0 else { return false }
            active += 1; group.enter()
            return true
        }
    }
    public func leave() {
        lock.withLock { active -= 1; group.leave() }
    }
    @discardableResult public func beginKey(maxWait: TimeInterval = 0.008) -> Bool {
        let busy = lock.withLock { keys += 1; return active > 0 }
        guard busy else { return true }
        let wait = max(0, min(0.008, maxWait))
        return waitOverride?(wait) ?? (group.wait(timeout: .now() + wait) == .success)
    }
    public func endKey() {
        lock.withLock { precondition(keys > 0); keys -= 1 }
    }
}

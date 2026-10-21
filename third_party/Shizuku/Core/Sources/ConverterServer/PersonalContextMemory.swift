import Core
import Foundation

/// Serverのメモリだけ。除外・学習オフ・忘却の境目で本文を捨てる。
final class PersonalContextMemory {
    nonisolated(unsafe) static let shared = PersonalContextMemory()
    var carry = PersonalAppCarry()
    var generation = PersonalLearner.shared.forgetGeneration
    var epoch = 0
    func reset() { carry = PersonalAppCarry(); epoch += 1 }
    var restored = 0, sent = 0, appCarried = 0, code = 0, markdown = 0
    func refresh() {
        if generation != PersonalLearner.shared.forgetGeneration {
            reset(); generation = PersonalLearner.shared.forgetGeneration
        }
    }
    func observe(app: String?, enabled: Bool, now: Double, previousApp: String? = nil) {
        if generation != PersonalLearner.shared.forgetGeneration || !enabled {
            reset()
            generation = PersonalLearner.shared.forgetGeneration
        }
        guard let app, enabled else { carry = PersonalAppCarry(); return }
        if PersonalPrivacy.isExcluded(app: app) { reset(); return }
        if let previousApp, previousApp != app, PersonalPrivacy.isExcluded(app: previousApp) { reset() }
        carry.observe(app: app, allowed: !PersonalPrivacy.isExcluded(app: app), now: now, previousApp: previousApp)
    }
    var summary: String { "文脈の確認 復元:\(restored)／送信後:\(sent)／アプリ移動:\(appCarried)／code:\(code)／md:\(markdown)" }
}

import Core
import Foundation

// MARK: - 退けた提案の記憶（llm-ime）
//
// Esc で退けた提案・いい感じ変換の取り消し・清書の取り消しを、場面の基本キーごとに覚え、同じ場面では同じ・近い提案を出さない。
// 欄ごとの指紋（dismissedOffers）と違い、欄やアプリを切り替えても 7 日間は残る。記憶の中だけで、ファイル・SQLite には書かない。
// 学習がオフ・記録しないアプリでは何もしない（従来の欄ごとの指紋だけ）。記録が消されたら（全部・アプリごと）すべて捨てる。
// ベクトルは文の埋め込みのモデルがすでに読まれているときだけ裏で作る（そのためにモデルを読まない）。キーの流れでは 2-gram だけで照合する。

@MainActor
final class DismissedOfferStore {
    static let shared = DismissedOfferStore()
    private var memory = DismissedOfferMemory()
    private var generation: Int?

    private func sync() {
        let current = PersonalLearner.shared.forgetGeneration
        if generation != current {
            memory.removeAll()
            generation = current
        }
    }

    func remember(_ text: String, scene: PersonalScene) {
        guard PersonalLearner.isEnabled, !PersonalPrivacy.isExcluded(app: scene.app), !PersonalPrivacy.looksSecret(text) else { return }
        sync()
        guard let id = memory.remember(text, scene: scene.baseKey, app: scene.app) else { return }
        PersonalEmbeddingService.shared.embedIfLoaded(text) { [weak self] vector in
            self?.memory.attach(vector: vector, to: id)
        }
    }

    func suppresses(_ text: String, scene: PersonalScene?, vector: [Float]? = nil) -> Bool {
        guard let scene, PersonalLearner.isEnabled, !PersonalPrivacy.isExcluded(app: scene.app) else { return false }
        sync()
        return memory.suppresses(text, scene: scene.baseKey, vector: vector)
    }
}

/// 画面の参考資料の有無ごとに、表示と採用を本文なしで数える（ウィンドウ文脈がオンのときだけ）
enum WindowEffectRecorder {
    static func note(kind: String, used: Bool, accepted: Bool, scene: PersonalScene?) {
        guard Config.WindowContextEnabled().value, PersonalLearner.isRecording, let scene,
              !PersonalPrivacy.isExcluded(app: scene.app) else { return }
        PersonalLearner.shared.recordReaction(kind: WindowReferenceEffect.reaction(kind: kind, used: used, accepted: accepted), scene: scene)
    }
}

extension ConverterServer {
    /// 欄ごとの指紋か、場面の記憶で退けたものか
    @MainActor
    func isDismissed(_ text: String, session: ConverterSession, scene: PersonalScene? = nil) -> Bool {
        session.personal.dismissedOffers.contains(AssistanceVerbs.fingerprint(text))
            || DismissedOfferStore.shared.suppresses(text, scene: scene ?? session.personal.scene)
    }

    /// 指紋に合う本文を、このセッションが今持っている提案から探して覚える（本文は Client から受け取らない）
    @MainActor
    func rememberDismissed(hash: String, session: ConverterSession, scene: PersonalScene?) {
        guard let scene else { return }
        var texts: [String] = []
        if let text = session.offers.current?.text { texts.append(text) }
        if let text = session.manager.nextTextCompletionSuggestion { texts.append(text) }
        if let text = session.personal.skeletonOffer?.text { texts.append(text) }
        if let text = session.lastKeyEventResponse?.snapshot.nextTextCompletion { texts.append(text) }
        if let text = session.cleanUpOffer?.text { texts.append(text) }
        texts += session.quoteCandidates
        if let text = texts.first(where: { AssistanceVerbs.fingerprint($0) == hash }) {
            DismissedOfferStore.shared.remember(text, scene: scene)
        }
    }
}

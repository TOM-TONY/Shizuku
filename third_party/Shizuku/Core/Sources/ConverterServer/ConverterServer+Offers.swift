import Core
import Foundation

extension ConverterServer {
    @MainActor
    func automaticOfferAllowed(_ kind: OfferKind, session: ConverterSession, scene: PersonalScene? = nil) -> Bool {
        guard AssistanceSettings.permits(kind, app: (scene?.app ?? session.activeAppID ?? session.personal.scene?.app)) else { return false }
        if let scene = scene ?? session.personal.scene, PersonalLearner.isEnabled,
           AssistanceSettings.app(scene.app).tab == .auto,
           [.completion, .idle, .skeleton].contains(kind),
           PersonalLearner.shared.tabOwnedByApplication(scene: scene) { return false }
        if session.personal.forgetGeneration != PersonalLearner.shared.forgetGeneration {
            session.beginOfferStop()
            session.personal.dropIfForgotten()
        }
        guard PersonalLearner.isRecording, let scene = scene ?? session.personal.scene,
              !PersonalPrivacy.isExcluded(app: scene.app), kind != .prediction else { return true }
        let key = PersonalOfferTrust.Key(scene: scene.baseKey, kind: kind)
        if let decision = session.offerDecisions[key] { return decision }
        let decision = PersonalLearner.shared.allowAutomaticOffer(kind, scene: scene)
        session.offerDecisions[key] = decision
        return decision
    }

    @MainActor
    func chooseOffer(_ offers: [Offer], session: ConverterSession) -> Offer? {
        session.offers.choose(offers.filter {
            AssistanceSettings.permits($0.kind, app: (session.activeAppID ?? session.personal.scene?.app))
                && !self.isDismissed($0.text, session: session)
        }, now: DispatchTime.now().uptimeNanoseconds,
                              temporal: PersonalLearner.isRecording && PersonalLearner.shared.hasOfferHistory)
    }

    /// 実際に選んだものだけをshownに数える。pollや同じ応答の再送では数えない。
    @MainActor
    func notePresentedOffer(session: ConverterSession, scene: PersonalScene? = nil) {
        guard let offer = session.offers.newlyPresented(), PersonalLearner.isRecording,
              let scene = scene ?? session.personal.scene, !PersonalPrivacy.isExcluded(app: scene.app) else { return }
        let state = session.personal, learner = PersonalLearner.shared
        switch offer.kind {
        case .completion:
            self.notePersonalCompletionShown(session: session, text: session.manager.nextTextCompletionSuggestion ?? offer.text)
            learner.recordReaction(kind: "completion_shown", scene: scene)
            WindowEffectRecorder.note(kind: "completion", used: session.completionUsedReference, accepted: false, scene: scene)
        case .typo:
            if let previous = state.typoShown, previous != offer.text, !state.typoAccepted {
                learner.recordReaction(kind: "typo_ignored", scene: scene, a: previous, b: state.typoTarget)
            }
            if state.typoShown != offer.text { state.typoAccepted = false }
            state.typoShown = offer.text
            if let prediction = offer.predictions.first {
                state.typoTarget = String(session.manager.convertTarget.dropLast(prediction.deleteCount)) + prediction.appendText
            }
            learner.recordReaction(kind: "typo_shown", scene: scene)
        case .rewrite:
            learner.recordReaction(kind: "rewrite_shown", scene: scene, n: state.rewriteHiddenCompletion == nil ? 0 : 1)
        case .skeleton:
            learner.recordReaction(kind: "skeleton_shown", scene: scene, a: offer.text)
        case .idle:
            self.notePersonalIdleCompletion(session: session, shown: offer.text)
        case .quote: break // 引用は明示した三択だけ。shownは実際の行が表示されたときに受け取る。
        case .cleanup: break // 清書はClientが実際に表示したときにcleanup_shownを送る。
        case .prediction: break
        }
    }

    @MainActor
    func emptyOffer(_ kind: OfferKind, text: String, session: ConverterSession, scene: PersonalScene? = nil) -> String? {
        guard AssistanceSettings.permits(kind, app: (scene?.app ?? session.activeAppID ?? session.personal.scene?.app)) else { return nil }
        guard !self.isDismissed(text, session: session, scene: scene) else { return nil }
        if let current = session.offers.current,
           !AssistanceSettings.permits(current.kind, app: (scene?.app ?? session.activeAppID ?? session.personal.scene?.app)) { session.offers.reset() }
        let sceneKey = (scene ?? session.personal.scene)?.baseKey
        if let previous = session.emptyOfferScene, let sceneKey, previous != sceneKey {
            session.offers.reset()
            session.personal.skeletonOffer = nil
        }
        if let sceneKey { session.emptyOfferScene = sceneKey }
        let selected = session.offers.chooseEmpty(.init(kind, text: text),
            skeleton: session.personal.skeletonOffer.map { .init(.skeleton, text: $0.text) },
            now: DispatchTime.now().uptimeNanoseconds,
            temporal: PersonalLearner.isRecording && PersonalLearner.shared.hasOfferHistory)
        notePresentedOffer(session: session, scene: scene)
        return selected?.text
    }
}

import Core
import Foundation

extension ConverterServer {
    @MainActor
    func quoteChoices(session: ConverterSession, observation: ConverterSceneObservation, left: String, right: String?) -> ConverterServerResponse {
        session.quoteCandidates = []
        session.activeAppID = observation.bundleID
        guard PersonalLearner.isEnabled, let app = observation.bundleID, !PersonalPrivacy.isExcluded(app: app),
              AssistanceSettings.permits(.quote, app: app, automatic: false),
              var scene = PersonalScene.classify(observation: observation, leftContext: left, rightContext: right) else {
            var response = ConverterServerResponse(snapshot: .empty); response.quoteCandidates = []; return response
        }
        if let shape = PersonalMarkup.shape(left: left, right: right ?? "", monospaced: observation.monospaced == true) {
            scene.shape = shape; scene.reply = false
        }
        if let previous = session.personal.scene, previous.app == scene.app {
            scene.place = previous.place; scene.recipient = previous.recipient
        }
        session.personal.scene = scene
        session.personal.observation = observation
        session.personal.dropIfForgotten()
        session.quoteCandidates = PersonalQuotes.candidates(corpus: PersonalLearner.shared.corpus, scene: scene, context: left)
            .filter { !self.isDismissed($0, session: session, scene: scene) }
        session.quoteGeneration = PersonalLearner.shared.forgetGeneration
        NextTextCompletionEngine.shared.cancel(); session.manager.clearNextTextCompletion(); session.offers.reset()
        var response = ConverterServerResponse(snapshot: .empty)
        response.quoteCandidates = session.quoteCandidates
        return response
    }

    @MainActor
    func acceptQuote(_ text: String, session: ConverterSession) throws -> ConverterServerResponse {
        guard session.quoteGeneration == PersonalLearner.shared.forgetGeneration, session.quoteCandidates.contains(text),
              text.count <= 50, let scene = session.personal.scene, PersonalLearner.isEnabled,
              !PersonalPrivacy.isExcluded(app: scene.app),
              AssistanceSettings.permits(.quote, app: scene.app, automatic: false) else { return .init(handled: false, snapshot: .empty) }
        let id = PersonalLearner.shared.recordCommit(.init(scene: scene, kind: "quote", reading: nil, surface: text, defaultSurface: nil))
        PersonalLearner.shared.recordReaction(kind: "quote_accepted", scene: scene, commitID: id, n: text.count)
        if session.inputState == .replaceSuggestion { PersonalLearner.shared.recordReaction(kind: "ai_cancelled", scene: scene) }
        session.personal.lastCommit = id.map { ($0, Date()) }
        session.personal.lastCommitText = (text, Date())
        session.personal.resetComposition(); session.personal.compositionID = 0
        session.quoteCandidates = []
        session.clearReplaceSuggestions()
        session.inputState = .none; session.beginOfferStop()
        var response = try kanaKanjiConverter.withSession(session.conversionSessionID) {
            session.manager.stopComposition()
            return makeResponse(for: session, inputState: .none, effects: [.insertText(text)])
        }
        if let id { response.assistanceReceipt = registerRetention(text: text, kind: "quote", id: id, scene: scene, session: session) }
        return response
    }

    @MainActor
    func registerRetention(text: String, kind: String, id: Int64, scene: PersonalScene, session: ConverterSession) -> String {
        let now = Date().timeIntervalSince1970
        session.retentionChecks = session.retentionChecks.filter { now - $0.value.check.started <= 600 }
        let token = UUID().uuidString
        session.retentionChecks[token] = (.init(text: text, started: now), scene, id, kind)
        return token
    }

    @MainActor
    func checkRetention(token: String, left: String?, complete: Bool, session: ConverterSession) -> ConverterServerResponse {
        guard let pending = session.retentionChecks[token] else { return .init(snapshot: .empty) }
        let now = Date().timeIntervalSince1970
        guard now - pending.check.started >= 120 else { return .init(snapshot: .empty) }
        session.retentionChecks[token] = nil
        let kept = pending.check.retained(left: left, complete: complete, now: now)
        PersonalLearner.shared.recordReaction(kind: pending.kind + (kept == nil ? "_kept_missing" : "_kept"),
            scene: pending.scene, commitID: pending.id, b: String(pending.check.text.count), n: kept)
        return .init(snapshot: .empty)
    }
}

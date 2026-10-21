import Core
import Foundation

extension ConverterServer {
    @MainActor
    func abandonStall(session: ConverterSession) {
        guard PersonalLearner.isRecording, session.manager.personalization != nil, !session.manager.isEmpty,
              let scene = session.personal.scene, !PersonalPrivacy.isExcluded(app: scene.app) else { return }
        session.personal.stalls.didCommit = false
        let records = session.personal.stalls.afterKey(scene: scene, now: Date().timeIntervalSince1970,
            wasComposing: true, isEmpty: true, depth: nil)
        for record in records { self.recordStall(record, session: session) }
    }
    @MainActor
    func noteStallEntry(session: ConverterSession) {
        if let scene = session.personal.scene, session.personal.stalls.burstCharacters > 0 {
            PersonalLearner.shared.recordBurst(scene: scene, characters: session.personal.stalls.burstCharacters, now: Date().timeIntervalSince1970)
        }
        session.personal.stalls = PersonalStall.Tracker(entryKnown: true)
    }
    @MainActor
    func observeStallKey(session: ConverterSession, request: ConverterKeyEventRequest, action: ClientAction) {
        guard PersonalLearner.isRecording, session.manager.personalization != nil, let scene = session.personal.scene,
              let app = request.scene?.bundleID, !PersonalPrivacy.isExcluded(app: app) else {
            PersonalSensing.shared.configure(scene: nil)
            return
        }
        let state = session.personal
        if case .selectNumberCandidate(let number) = action {
            self.observeStallDepth(session: session, depth: request.visibleCandidateStartIndex + number - 1)
        }
        let now = Date().timeIntervalSince1970
        let list: Bool = if case .selecting = session.inputState { true } else { false }
        let confirming: Bool = if case .composing = session.inputState { request.liveConversionEnabled } else { false }
        let position = PersonalStall.position(left: request.context.leftSideContext, composing: !session.manager.isEmpty, candidates: list, confirming: confirming)
        let first = PersonalStall.action(action, composing: !session.manager.isEmpty,
            knownContinuation: request.context.leftSideContext != nil && (position == .middle || position == .particle),
            convertedBefore: state.stalls.convertedBefore)
        if case .enterCandidateSelectionMode = action { state.stalls.convertedBefore = true }
        let returnedAway = PersonalSensing.shared.noteKey(session: session, scene: scene, action: first, now: now)
        let gap = state.stalls.lastKey.map { now - $0 }
        let stopped = state.stalls.intervalRecord
        if let stopped, let gap {
            PersonalLearner.shared.finishStallInterval(id: stopped.id, seconds: gap)
            PersonalSensing.shared.returnedInterval(stopped, action: first, away: returnedAway || gap >= 90)
        }
        if let gap, gap >= 2, state.stalls.burstCharacters > 0 {
            PersonalLearner.shared.recordBurst(scene: scene, characters: state.stalls.burstCharacters, now: now)
            state.stalls.burstCharacters = 0
        }
        let records = state.stalls.beforeKey(scene: scene, now: now, composing: !session.manager.isEmpty, position: position,
            threshold: PersonalStall.threshold(scene: scene, intervals: PersonalLearner.shared.stallIntervals),
            emptyField: request.context.leftSideContext == "" && state.observation?.documentLength == 0,
            deletedCharacters: state.lastCommit.map { now - $0.time.timeIntervalSince1970 <= 120 } == true ? state.observation?.backspacesAfterCommit ?? 0 : 0)
        state.stalls.intervalRecord = nil
        if !session.manager.isEmpty, let gap { PersonalLearner.shared.recordStallInterval(scene: scene, seconds: gap, now: now) }
        for record in records {
            self.recordStall(record, session: session, first: first, away: returnedAway || (gap ?? 0) >= 90)
        }
    }
    @MainActor
    func finishStallKey(session: ConverterSession, wasComposing: Bool) {
        guard PersonalLearner.isRecording, session.manager.personalization != nil, let scene = session.personal.scene,
              !PersonalPrivacy.isExcluded(app: scene.app) else { return }
        let depth = session.manager.currentSelectionIndex
        let records = session.personal.stalls.afterKey(scene: scene, now: Date().timeIntervalSince1970,
            wasComposing: wasComposing, isEmpty: session.manager.isEmpty, depth: depth)
        for record in records { self.recordStall(record, session: session) }
        guard !session.manager.isEmpty, let last = session.personal.stalls.lastKey,
              let threshold = PersonalStall.threshold(scene: scene, intervals: PersonalLearner.shared.stallIntervals) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold + 0.001) { [weak self, weak session] in
            guard let self, let session, PersonalLearner.isRecording, session.manager.personalization != nil,
                  PersonalSensing.shared.isActive(session: session), session.personal.stalls.lastKey == last, !session.manager.isEmpty,
                  session.personal.stalls.intervalRecord == nil, !PersonalPrivacy.isExcluded(app: scene.app) else { return }
            let now = Date().timeIntervalSince1970
            let record = PersonalStall.Record(scene: scene, event: .interval, position: session.personal.stalls.position,
                seconds: now - last, now: now)
            session.personal.stalls.intervalRecord = record
            self.recordStall(record, session: session)
        }

    }
    @MainActor
    func observeStallDepth(session: ConverterSession, depth: Int?) {
        guard PersonalLearner.isRecording, session.manager.personalization != nil, let scene = session.personal.scene,
              !PersonalPrivacy.isExcluded(app: scene.app) else { return }
        let records = session.personal.stalls.afterKey(scene: scene, now: Date().timeIntervalSince1970,
            wasComposing: false, isEmpty: false, depth: depth)
        for record in records { self.recordStall(record, session: session) }
    }
    @MainActor
    private func recordStall(_ record: PersonalStall.Record, session: ConverterSession, first: PersonalStall.Action? = nil, away: Bool = false) {
        PersonalLearner.shared.recordStall(record)
        if record.event == .deleted, let last = session.personal.lastCommit {
            PersonalLearner.shared.linkStalls([record.id], commitID: last.id, now: record.ts)
        } else { session.personal.stalls.append(record) }
        PersonalSensing.shared.sample(record, first: first, away: away)
    }
}

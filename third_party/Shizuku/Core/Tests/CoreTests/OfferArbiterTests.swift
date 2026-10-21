import Foundation
import Testing
@testable import Core

@Test func arbiterUsesLegacyOrderAndOneOfferWithoutLearningOrHistory() {
    let typo = Offer(.typo, text: "fixed", predictions: [.init(displayText: "fixed", appendText: "x")])
    let rewrite = Offer(.rewrite, text: "rewritten", predictions: [.init(displayText: "rewritten", appendText: "")])
    let completion = Offer(.completion, text: "continued")
    let prediction = Offer(.prediction, text: "dictionary", predictions: [.init(displayText: "dictionary", appendText: "y")])
    for hasTypo in [false, true] {
        for hasRewrite in [false, true] {
            for hasCompletion in [false, true] {
                var arbiter = OfferArbiter()
                let offers = (hasTypo ? [typo] : []) + (hasRewrite ? [rewrite] : []) + (hasCompletion ? [completion] : []) + [prediction]
                let selected = arbiter.choose(offers, now: 0, temporal: false)
                let expected = hasTypo ? typo : hasRewrite ? rewrite : hasCompletion ? completion : prediction
                #expect({ selected == expected }())
                if !hasRewrite && !hasCompletion {
                    let legacy = SegmentsManager.preferredPredictionCandidates(
                        typoCorrectionCandidates: hasTypo ? [.init(displayText: "fixed", appendText: "x")] : [],
                        predictionCandidates: [.init(displayText: "dictionary", appendText: "y")])
                    #expect({ selected?.predictions == legacy.map(ConverterPredictionCandidate.init) }())
                }
            }
        }
    }
}

@Test func arbiterMeasures150MillisecondsFromFirstDisplayAndRetainsTheVisibleAcceptPayload() {
    let generated = Offer(.completion, text: "lower")
    let quoted = Offer(.skeleton, text: "quote")
    let fixed = Offer(.typo, text: "upper", predictions: [.init(displayText: "upper", appendText: "fixed", deleteCount: 2)])
    for delay: UInt64 in [149_000_000, 150_000_000, 150_000_001] {
        var arbiter = OfferArbiter()
        #expect({ arbiter.choose([generated], now: 10, temporal: true) == generated }())
        #expect({ arbiter.newlyPresented() == generated }())
        #expect({ arbiter.newlyPresented() == nil }())
        let chosen = arbiter.choose([fixed, quoted, generated], now: 10 + delay, temporal: true)
        #expect({ chosen == (delay <= 150_000_000 ? fixed : generated) }())
        #expect({ arbiter.current == chosen }())
        if delay > 150_000_000 { #expect({ arbiter.current?.predictions.isEmpty == true }()) }
        arbiter.reset()
        #expect({ arbiter.choose([quoted, generated], now: 999_000_000, temporal: true) == quoted }())
        #expect({ !arbiter.mayPrepare(.idle) }())
    }
    var arbiter = OfferArbiter()
    _ = arbiter.choose([generated], now: 0, temporal: false)
    #expect({ arbiter.choose([fixed, generated], now: 2_000_000_000, temporal: false) == fixed }())
}

@Test func dictionaryDoesNotStartTheReplacementDeadlineAndInvalidOffersAreNotRetained() {
    var arbiter = OfferArbiter()
    let dictionary = Offer(.prediction, text: "dictionary")
    let generated = Offer(.completion, text: "generated")
    let correction = Offer(.rewrite, text: "correction")
    _ = arbiter.choose([dictionary], now: 0, temporal: true)
    #expect({ arbiter.choose([dictionary, generated], now: 5_000_000_000, temporal: true) == generated }())
    #expect({ arbiter.choose([correction], now: 9_000_000_000, temporal: true) == correction }())
    #expect({ arbiter.choose([], now: 10_000_000_000, temporal: true) == nil }())
}

@Test func wilsonNeedsTwentyShowsExploresEveryTenthOpportunityAndRecoversAtThreeAcceptances() {
    let scene = PersonalScene(app: "test", shape: .line, mode: .new, reply: false, place: "place", recipient: .r2)
    let key = PersonalOfferTrust.Key(scene: scene.key, kind: .completion)
    #expect({ key.scene == scene.baseKey }())
    var trust = PersonalOfferTrust()
    #expect({ PersonalOfferTrust.wilson(shown: 0, accepted: 0) == 0 }())
    for i in 0..<19 { trust.observe(reaction: "completion_shown", scene: scene.key, ts: Double(i)) }
    #expect({ trust.allow(key, now: 20) }())
    trust.observe(reaction: "completion_shown", scene: scene.key, ts: 19)
    #expect({ trust.status(key, now: 20).muted }())
    for i in 1...20 { #expect({ trust.allow(key, now: 20) == (i % 10 == 0) }()) }
    for i in 0..<2 { trust.observe(reaction: "completion_accepted", scene: scene.key, ts: 20 + Double(i)) }
    #expect({ abs(trust.status(key, now: 22).lowerBound - 0.0278664812137682) < 1e-10 }())
    #expect({ trust.status(key, now: 22).muted }())
    trust.observe(reaction: "completion_accepted", scene: scene.key, ts: 23)
    #expect({ trust.status(key, now: 23).lowerBound > 0.05 }())
    #expect({ trust.allow(key, now: 23) }())
    #expect({ !trust.status(.init(scene: scene.key, kind: .idle), now: 23).muted }())
    #expect({ !trust.status(key, now: PersonalOfferTrust.window + 30).muted }())
}

@Test func trustIgnoresUnpairedLegacyAcceptancesAndDeletionRemovesBothEvidenceAndExploration() {
    var trust = PersonalOfferTrust()
    let key = PersonalOfferTrust.Key(scene: "test|line|new|-", kind: .skeleton)
    for _ in 0..<20 { trust.observe(reaction: "skeleton_accepted", scene: key.scene, ts: 0) }
    for i in 0..<20 { trust.observe(reaction: "skeleton_shown", scene: key.scene, ts: Double(i)) }
    #expect({ trust.status(key, now: 20).accepted == 0 }())
    #expect({ !trust.allow(key, now: 20) }())
    trust.forget(app: "test")
    #expect({ trust.allow(key, now: 20) }())
    #expect({ trust.muted(now: 20).isEmpty }())
}

@Test func lateEmptyFieldQuoteRetainsIdleAndAcceptanceOrMicrophoneClearsTheOldGeneration() {
    var arbiter = OfferArbiter()
    let idle = Offer(.idle, text: "generated"), skeleton = Offer(.skeleton, text: "quote")
    let first = arbiter.chooseEmpty(idle, skeleton: nil, now: 0, temporal: true)
    #expect(first == idle)
    let late = arbiter.chooseEmpty(skeleton, skeleton: nil, now: 150_000_001, temporal: true)
    #expect(late == idle)
    arbiter.reset()
    #expect(arbiter.mayPrepare(.idle))
    _ = arbiter.chooseEmpty(skeleton, skeleton: nil, now: 0, temporal: true)
    arbiter.invalidateGeneration()
    #expect(arbiter.current == nil)
    _ = arbiter.choose([.init(.typo, text: "fix")], now: 0, temporal: true)
    arbiter.invalidateGeneration()
    #expect(arbiter.current?.kind == .typo)
}

@Test @MainActor func learnerUsesOnlyReactionCountsAndClearsTrustOnDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersonalStore(url: directory.appendingPathComponent("test.sqlite"))
    let learner = PersonalLearner(storeURL: nil); learner.attachStoreForTesting(store)
    let scene = PersonalScene(app: "test", shape: .line, mode: .new, reply: false)
    #expect(!learner.hasOfferHistory)
    for _ in 0..<20 { learner.recordReaction(kind: "skeleton_shown", scene: scene) }
    #expect(learner.commitCount == 0 && learner.hasOfferHistory)
    learner.flush()
    #expect({ learner.offerTrustSummary().contains("場面×種類 1 件") }())
    for i in 1...10 { #expect({ learner.allowAutomaticOffer(.skeleton, scene: scene) == (i == 10) }()) }
    for _ in 0..<3 { learner.recordReaction(kind: "skeleton_accepted", scene: scene) }
    #expect({ learner.allowAutomaticOffer(.skeleton, scene: scene) }())
    learner.deleteAll(); learner.flush()
    #expect(!learner.hasOfferHistory)
    #expect({ learner.offerTrustSummary().contains("場面×種類 0 件") }())
    try await Task.sleep(for: .milliseconds(30)); learner.flush()
}

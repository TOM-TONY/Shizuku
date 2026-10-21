import Foundation
import Testing
@testable import Core

private let styleScene = PersonalScene(app: "editor", shape: .line, mode: .new, reply: false)
private func styleObserve(_ profile: inout PersonalStyleProfile, text: String, n: Int, scene: PersonalScene = styleScene) {
    for _ in 0..<n { profile.observe(scene: scene, text: text) }
}

@Test func styleCountsRequireTenObservationsAndEightyPercentForEachItem() throws {
    var profile = PersonalStyleProfile()
    styleObserve(&profile, text: "確認！", n: 7)
    styleObserve(&profile, text: "確認!", n: 2)
    #expect(profile.preferences(levels: [styleScene.key])[1] == nil)
    styleObserve(&profile, text: "確認！", n: 1)
    #expect(profile.preferences(levels: [styleScene.key])[1] == 0)
    styleObserve(&profile, text: "確認!", n: 1)
    #expect(profile.preferences(levels: [styleScene.key])[1] == nil)
    #expect(profile.counts[styleScene.key]?[1] == .init(first: 8, second: 3))
}

@Test func stylePairsNeedFiveObservationsAndUseTheFinestQualifiedLevelPerItem() throws {
    var profile = PersonalStyleProfile()
    styleObserve(&profile, text: "下さい。確認！", n: 20)
    let place = PersonalScene(app: "editor", shape: .line, mode: .new, reply: false, place: "example.test")
    styleObserve(&profile, text: "ください!", n: 4, scene: place)
    #expect(profile.preferences(levels: PersonalStyleProfile.levels(place))[6] == 0)
    styleObserve(&profile, text: "ください!", n: 1, scene: place)
    let preferences = profile.preferences(levels: PersonalStyleProfile.levels(place))
    #expect(preferences[6] == 1) // 5件の場所の段が、場面の段を上書きする。
    #expect(preferences[1] == 0) // 場所の記号は5件だけなので、基底の20:5（8割）へ後退。
    let other = PersonalScene(app: "editor", shape: .doc, mode: .edit, reply: false)
    #expect(profile.preferences(levels: PersonalStyleProfile.levels(other))[6] == 0) // 未観測の場面はアプリの20:5へ後退。
    #expect(PersonalStyleProfile.levels(nil) == ["global"])
    #expect(profile.preferences(levels: PersonalStyleProfile.levels(nil))[6] == 0)
}

@Test func stylePunctuationBracketsDigitsAndTerminalPeriodAreDeterministic() throws {
    var profile = PersonalStyleProfile()
    styleObserve(&profile, text: "確認！（予定）？１、２です。", n: 10)
    let plan = try #require(profile.plans()[styleScene.key])
    #expect(plan.apply("確認!(予定)?1，2です") == "確認！（予定）？１、２です。")
    var open = PersonalStyleProfile()
    styleObserve(&open, text: "確認!(予定)?1，2です", n: 10)
    let reverse = try #require(open.plans()[styleScene.key])
    #expect(reverse.apply("確認！（予定）？１、２です。") == "確認!(予定)?1，2です")
    #expect(plan.apply(plan.apply("確認!(予定)?1，2です")) == plan.apply("確認!(予定)?1，2です"))
}

@Test func styleWordBoundariesDoNotChangeCompoundsOrAmbiguousPairs() throws {
    let word = try #require(PersonalOrthography.pairs.firstIndex { $0.closed == "事" })
    let plan = PersonalStylePlan(preferences: [word + 6: 1])
    #expect(plan.apply("事務と記事を確認する事。") == "事務と記事を確認すること。")
    let reverse = PersonalStylePlan(preferences: [word + 6: 0])
    #expect(reverse.apply("まことにありがとうございます。ことばを確認すること。") == "まことにありがとうございます。ことばを確認する事。")
    #expect(!PersonalOrthography.pairs.contains { ["様", "位", "何時"].contains($0.closed) })
    #expect(PersonalOrthography.pairs.count == 40)
}

@Test func styleProfileAcceptsOnlyAuthoredOrPromotedNormalCommits() throws {
    func row(_ kind: String, _ origin: Int) -> LabCommit {
        LabCommit(ts: 1, scene: styleScene.key, kind: kind, reading: nil, surface: "確認！", first: nil, left: nil, origin: origin)
    }
    let excluded = PersonalStyleProfile(rows: [LabCommit](repeating: row("ai", 0), count: 10) + [LabCommit](repeating: row("enter", 1), count: 10))
    #expect(excluded.plans().isEmpty)
    let included = PersonalStyleProfile(rows: [LabCommit](repeating: row("enter", 2), count: 10))
    #expect(included.preferences(levels: [styleScene.key])[1] == 0)
}

@Test func styleGeneratedRoutesAlwaysBypassProofreadingConversionAndInteractiveCompletion() {
    let original = "確認!1。"
    let plan = PersonalStylePlan(preferences: [0: 1, 1: 0, 5: 0])
    for route in [PersonalGeneratedText.Route.proofread, .conversion, .completion] {
        #expect(PersonalGeneratedText.apply(original, route: route, enabled: true, plan: plan) == original)
        let decomposed = "か\u{3099}くにん!1。"
        #expect(Data(PersonalGeneratedText.apply(decomposed, route: route, enabled: true, plan: plan).utf8) == Data(decomposed.utf8))
    }
    for route in [PersonalGeneratedText.Route.magic, .transform, .draft, .idle] {
        #expect(PersonalGeneratedText.apply(original, route: route, enabled: true, plan: plan) == "確認！１")
        #expect(PersonalGeneratedText.apply(original, route: route, enabled: false, plan: plan) == original)
        #expect(PersonalGeneratedText.apply(original, route: route, enabled: true, plan: nil) == original)
    }
    #expect(PersonalStylePlan(preferences: [:]).apply(original) == original)
}

@Test func styleUnchangedPreferencesReusePreparedPlans() throws {
    var profile = PersonalStyleProfile()
    styleObserve(&profile, text: "確認！", n: 10)
    let before = profile.plans()
    styleObserve(&profile, text: "確認！", n: 1)
    let after = profile.plans(reusing: before)
    #expect(try #require(before[styleScene.key]) === #require(after[styleScene.key]))
}

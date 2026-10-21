import Foundation
import Testing
@testable import Core

private let honorificScene = PersonalScene(app: "test.editor", shape: .line, mode: .new, reply: false)
private func honorificProfile(_ text: String, times: Int, scene: PersonalScene = honorificScene) -> PersonalStyleProfile {
    var profile = PersonalStyleProfile()
    for _ in 0..<times { profile.observe(scene: scene, text: text) }
    return profile
}

@Test func honorificTableHasOneHundredTwentyUniqueGroups() {
    #expect(PersonalHonorific.groups.count == 120)
    #expect(PersonalHonorific.groups.allSatisfy { $0.count >= 2 })
    #expect(Set(PersonalHonorific.variants).count == PersonalHonorific.variants.count)
}

@Test func honorificTrieKeepsLongestNonOverlappingWordMatchesForEveryTableTerm() throws {
    let expression = try NSRegularExpression(pattern: PersonalHonorific.variants.sorted {
        $0.count != $1.count ? $0.count > $1.count : $0 < $1
    }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))
    let words = PersonalOrthography.Words()
    for term in PersonalHonorific.variants {
        let text = "前の文。" + term + "。😊" + term + "ません。"
        let boundaries = words.boundaries(text)
        let expected = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { match -> Int? in
            guard let range = Range(match.range, in: text), boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound) else { return nil }
            return PersonalHonorific.ids[String(text[range])]
        }
        #expect(PersonalHonorific.matches(text, words: words).map(\.id) == expected)
    }
}

@Test func honorificReplacementNeedsTwoUsesOfAnAlternativeAndNoUseOfTheSource() throws {
    let one = honorificProfile("確認してください。", times: 1)
    #expect(try #require(one.plans()[honorificScene.key]).apply("ご確認ください。") == "ご確認ください。")
    var two = honorificProfile("確認してください。", times: 2)
    let plan = try #require(two.plans()[honorificScene.key])
    #expect(plan.apply("ご確認ください。") == "確認してください。")
    #expect(plan.apply(plan.apply("ご確認ください。")) == "確認してください。")
    two.observe(scene: honorificScene, text: "ご確認ください。")
    #expect(try #require(two.plans()[honorificScene.key]).apply("ご確認ください。") == "ご確認ください。")
}

@Test func honorificUsageSelectsTheFinestQualifiedGroupAndFallsBackIndependently() throws {
    var profile = honorificProfile("確認してください。すみません。", times: 3)
    let place = PersonalScene(app: honorificScene.app, shape: .line, mode: .new, reply: false, place: "example.test")
    for _ in 0..<2 { profile.observe(scene: place, text: "ご確認ください。") }
    let plan = try #require(profile.plans()[place.key])
    #expect(plan.apply("確認してください。申し訳ございません。") == "ご確認ください。すみません。")
    let other = PersonalScene(app: honorificScene.app, shape: .doc, mode: .edit, reply: false)
    #expect(profile.honorificUsage(levels: PersonalStyleProfile.levels(other))[PersonalHonorific.ids["確認してください"]!] == 3)
}

@Test func honorificCountsUseLongestNonOverlappingTermsAndDeterministicTies() throws {
    var profile = honorificProfile("承知しました。", times: 2)
    for _ in 0..<2 { profile.observe(scene: honorificScene, text: "わかりました。") }
    let plan = try #require(profile.plans()[honorificScene.key])
    #expect(plan.apply("承知いたしました。") == "承知しました。")
    let long = honorificProfile("何卒よろしくお願いいたします。", times: 2)
    #expect(long.honorificCounts[honorificScene.key]?[PersonalHonorific.ids["何卒よろしくお願いいたします"]!] == 2)
    #expect(long.honorificCounts[honorificScene.key]?[PersonalHonorific.ids["よろしくお願いいたします"]!] == nil)
}

@Test func honorificMaterialAndRoutesExcludeModelSourcesAndProofreading() throws {
    let rows = (0..<2).map { LabCommit(ts: Double($0), scene: honorificScene.key, kind: "enter", reading: nil,
                                      surface: "確認してください。", first: nil, left: nil, origin: 1) }
    #expect(PersonalStyleProfile(rows: rows).honorificCounts.isEmpty)
    let plan = try #require(honorificProfile("確認してください。", times: 2).plans()[honorificScene.key])
    let text = "ご確認ください。"
    for route in [PersonalGeneratedText.Route.proofread, .completion, .conversion] {
        #expect(Data(PersonalGeneratedText.apply(text, route: route, enabled: true, plan: plan).utf8) == Data(text.utf8))
    }
    #expect(PersonalGeneratedText.apply(text, route: .magic, enabled: false, plan: plan) == text)
    #expect(PersonalGeneratedText.apply(text, route: .magic, enabled: true, plan: plan) == "確認してください。")
}

@Test func honorificProtectedTermsAndContaminationContainOnlyTableTerms() throws {
    let profile = honorificProfile("確認してください。", times: 2)
    let usage = profile.honorificUsage(levels: PersonalStyleProfile.levels(honorificScene))
    #expect(PersonalHonorific.protectedTerms(usage: usage) == ["確認してください"])
    #expect(PersonalHonorific.containsUnused("ご確認ください。", usage: usage))
    #expect(!PersonalHonorific.containsUnused("確認してください。", usage: usage))
    let plain = LocalLLMPrompts.proofreadUserPrompt(text: "原文", before: "", after: "")
    let added = LocalLLMPrompts.proofreadUserPrompt(text: "原文", before: "", after: "", protectedTerms: ["確認してください", "宛名テスト", "確認してください"])
    #expect(added.replacingOccurrences(of: "直さない語: 確認してください\n", with: "") == plain)
    #expect(!added.contains("宛名テスト"))
    let legacy = """
    次の文章を校正してください。直すのは、明らかな誤りだけです。
    - 直す: 誤字、脱字、余計な文字、変換ミス（同音の別の漢字）、助詞の誤り、明らかな文法の誤り
    - 直さない: 読点（、）の追加や削除、漢字とひらがなの書き分け（為/ため、事/こと など）、言い回しや語順、
      全角・半角、固有名詞、意味が通る表現
    - 確信が持てないときは直さない。誤りがなければ、文章を一字一句そのまま返す
    - 直した文章だけを出力する（説明は書かない）

    文章: 原文
    """
    #expect(Data(plain.utf8) == Data(legacy.utf8))
    #expect(PersonalHonorific.protectedTerms(usage: [PersonalHonorific.ids["確認してください"]!: 1]).isEmpty)
}

@Test func honorificOwnPhraseWinsWhenOrthographyWouldOverlapIt() {
    let plan = PersonalStylePlan(preferences: [6: 0], honorificUsage: [PersonalHonorific.ids["確認してください"]!: 2])
    #expect(plan.apply("ご確認ください。") == "確認してください。")
}

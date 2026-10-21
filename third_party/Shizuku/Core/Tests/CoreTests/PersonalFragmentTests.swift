import Foundation
import Testing
@testable import Core

@Test func magicFragmentsRespectReadingAliasesAndOnlyReportKnownContent() {
    let tokens: [PersonalFragments.Token] = [.init(surface: "明日", reading: "アシタ"), .init(surface: "会議", reading: "カイギ"), .init(surface: "は", reading: "ハ")]
    #expect(PersonalFragments.missing(input: "あしたかいぎ", output: "明日は休みです。", tokens: tokens) == ["会議"])
    #expect(PersonalFragments.missing(input: "あしたかいぎ", output: "あした会議です。", tokens: tokens).isEmpty)
    #expect(PersonalFragments.missing(input: "あしたかいぎ", output: "別の文", tokens: []).isEmpty)
    #expect(PersonalFragments.missing(input: "会議12時", output: "12時の会議です。", tokens: []).isEmpty)
    #expect(PersonalFragments.missing(input: "PR 資料", output: "ＰＲの案です。", tokens: []) == ["資料"])
}

@Test func newMagicResponseFieldsAreAbsentFromOrdinaryWireResponses() throws {
    let response = ConverterServerResponse(snapshot: .empty)
    let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    #expect(!json.contains("magicFragments"))
    #expect(!json.contains("assistanceReceipt"))
    for command: ConverterReplaceSuggestionCommand in [.submitGenerated, .cancelGenerated, .appendFragments(all: false)] {
        _ = try JSONDecoder().decode(ConverterReplaceSuggestionCommand.self, from: JSONEncoder().encode(command))
    }
}
